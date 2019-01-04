{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase    #-}

module Cardano.Wallet.Client.Wait
  ( waitForSomething
  , WaitOptions(..)
  , waitOptionsPID
  , SyncResult(..)
  , SyncError(..)
  ) where

import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (AsyncCancelled (..),
                     waitEitherCatchCancel, withAsync)
import           Control.Concurrent.STM.TVar (modifyTVar', newTVar, readTVar)
import           Control.Retry
import           Criterion.Measurement (getTime, initializeTime)
import           Data.Aeson (ToJSON (..), Value (..), object, (.=))
import           Data.Default
import qualified Data.DList as DList
import           Data.Time.Clock (UTCTime, getCurrentTime)
import           Formatting (bprint, fixed, sformat, shown, stext, (%))
import           Formatting.Buildable (Buildable (..))
import           Universum

import           Cardano.Wallet.API.Response (APIResponse (..))
import           Cardano.Wallet.Client (ClientError (..), Resp,
                     WalletClient (..))
import           Cardano.Wallet.ProcessUtil


data WaitOptions = WaitOptions
  { waitTimeoutSeconds  :: !(Maybe Double)  -- ^ Timeout in seconds
  , waitProcessID       :: !(Maybe ProcessID) -- ^ Wallet process ID, so that crashes are handled
  , waitIntervalSeconds :: !Double -- ^ Time between polls
  } deriving (Show, Eq)

instance Default WaitOptions where
  def = WaitOptions Nothing Nothing 1.0

data SyncResult r = SyncResult
  { syncResultError     :: !(Maybe SyncError)
  , syncResultStartTime :: !UTCTime
  , syncResultDuration  :: !Double
  , syncResultData      :: ![(Double, r)]
  } deriving (Show, Eq, Typeable, Generic)

data SyncError = SyncErrorClient ClientError
               | SyncErrorProcessDied ProcessID
               | SyncErrorTimedOut Double
               | SyncErrorException SomeException
               | SyncErrorInterrupted
               deriving (Show, Typeable, Generic)

instance Buildable SyncError where
  build (SyncErrorClient err) = bprint ("There was an error connecting to the wallet: "%shown) err
  build (SyncErrorProcessDied pid) = bprint ("The cardano-node process with pid "%shown%" has gone") pid
  build (SyncErrorTimedOut t) = bprint ("Timed out after "%fixed 1%" seconds") t
  build (SyncErrorException e) = build e
  build SyncErrorInterrupted = build ("Interrupted" :: Text)

instance Eq SyncError where
  SyncErrorClient a      == SyncErrorClient b      = a == b
  SyncErrorProcessDied a == SyncErrorProcessDied b = a == b
  SyncErrorTimedOut a    == SyncErrorTimedOut b    = a == b
  SyncErrorInterrupted   == SyncErrorInterrupted   = True
  SyncErrorException _   == SyncErrorException _   = True
  _ == _ = False

instance ToJSON r => ToJSON (SyncResult r) where
  toJSON (SyncResult err st dur rs) =
    object $ ["data" .= toJSON rs, "start_time" .= st, "duration" .= dur] <> status err
    where
      status Nothing  = [ "success" .= True ]
      status (Just e) = [ "success" .= False, "error" .= String (show e) ]

instance ToJSON SyncError where
  toJSON e = String (show e)


-- | Really basic timing information.
time :: ((IO Double) -> IO a) -> IO (UTCTime, Double, a)
time act = do
  initializeTime
  startUTC <- getCurrentTime
  start <- getTime
  res <- act (fmap (\t -> t - start) getTime)
  finish <- getTime
  pure (startUTC, finish - start, res)

waitOptionsPID :: Maybe ProcessID -> WaitOptions
waitOptionsPID pid = def { waitProcessID = pid }

waitForSomething :: (WalletClient IO -> Resp IO a) -- ^ Action to run on wallet
                 -> (a -> IO (Bool, Text, r)) -- ^ Action to interpret wallet response
                 -> WaitOptions
                 -> WalletClient IO -- ^ Wallet client
                 -> IO (SyncResult r)
waitForSomething req check WaitOptions{..} wc = do
  rv <- atomically $ newTVar DList.empty
  (start, dur, res) <- time $ \getElapsed -> do
    withAsync (timeoutSleep waitTimeoutSeconds) $ \sleep ->
      withAsync (retrying policy (check' rv getElapsed) action) $ \poll -> cancelOnExit poll $
        waitEitherCatchCancel sleep poll

  rs <- atomically $ readTVar rv

  -- Unwrap layers of error handling and convert to Maybe SyncError
  let e = case res of
            Left _ -> SyncErrorTimedOut <$> waitTimeoutSeconds
            Right (Left err) -> case fromException err of
              Just AsyncCancelled -> Just SyncErrorInterrupted
              Nothing             -> Just (SyncErrorException err)
            Right (Right (False, _)) -> (SyncErrorProcessDied <$> waitProcessID)
            Right (Right (_, Left err)) -> (Just (SyncErrorClient err))
            Right _ -> Nothing

  pure $ SyncResult e start dur (DList.toList rs)

  where
    policy = constantDelay (toMicroseconds waitIntervalSeconds)

    -- Run the given action and test that the server is still running
    action _st = (,) <$> checkProcessExists waitProcessID <*> req wc

    -- Interpret result of action, log some info, decide whether to continue
    check' _ _ _st (False, _) = do
      logStatus $ sformat "Wallet is no longer running"
      pure False
    check' rv getElapsed _st (_, Right resp) = do
      (unfinished, msg, res) <- check (wrData resp)
      elapsed <- getElapsed
      atomically $ modifyTVar' rv (flip DList.snoc (elapsed, res))
      when unfinished $
        logStatus $ sformat (fixed 2%" "%stext) elapsed msg
      pure unfinished
    check' _ _ _st (True, Left err) = do
      logStatus $ sformat ("Error connecting to wallet: "%shown) err
      pure True

    logStatus = putStrLn

-- | Sleep for the given time in seconds, or indefinitely.
timeoutSleep :: Maybe Double -> IO ()
timeoutSleep (Just s) = threadDelay (toMicroseconds s)
timeoutSleep Nothing  = forever $ threadDelay (toMicroseconds 1000)

-- | Convert seconds to microseconds
toMicroseconds :: Double -> Int
toMicroseconds s = floor (s * oneSec)

oneSec :: Num a => a
oneSec = 1000000
