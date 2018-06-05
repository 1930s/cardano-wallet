-- | Function for running a client, for @NewWallet@.

module Client.Cardano.Wallet.Web.Endpoint.NewWallet
    ( newWalletIO
    ) where

import           Universum

import           Crypto.Random.Entropy (getEntropy)
import           Data.Time.Clock (getCurrentTime)

import           Bench.Cardano.Wallet.Types (BenchEndpoint (..), CompleteConfig (..), Response,
                                             ResponseReport (..))
import           Client.Cardano.Wallet.Web.Analyze (analyzeResponseIfNeeded, checkResponse)
import           Client.Cardano.Wallet.Web.Api (newWallet)
import           Client.Cardano.Wallet.Web.Run (runEndpointClient)
import           Pos.Util.Mnemonic (Mnemonic, entropyToMnemonic, mkEntropy)
import           Pos.Wallet.Web.ClientTypes (CWallet (..), CWalletAssurance (..), CWalletInit (..),
                                             CWalletMeta (..))

-- | Run 'NewWallet' client. As a result we will get a newly created wallet.
newWalletIO :: CompleteConfig -> IO ()
newWalletIO conf@CompleteConfig {..} = do
    timeForNow <- getCurrentTime
    backupPhrase <- generateBackupPhrase
    let walletName = "Wallet " <> show timeForNow -- For unique name of wallet.
        assurance  = CWAStrict
        smallUnit  = 1 -- For Lovelaces
        initMeta   = CWalletMeta walletName assurance smallUnit
        walletInit = CWalletInit initMeta backupPhrase
        passPhrase = Nothing -- Don't use passphrase, for simplicity.
    response <- runEndpointClient conf $ newWallet passPhrase walletInit
    analyzeResponseIfNeeded NewWalletBench conf $ analyze response

-- | Generate new backup phrase for new wallet.
generateBackupPhrase :: IO Mnemonic
generateBackupPhrase = do
    -- The size 16 should give us 12-words mnemonic after BIP-39 encoding.
    bytes <- getEntropy 16
    either (error . show) (return . entropyToMnemonic) (mkEntropy bytes)

-- | Analyze response with new address.
analyze
    :: Response CWallet
    -> ResponseReport
analyze response =
    checkResponse response
                  "Cannot create new wallet"
                  $ \createdWallet -> ResponseReport $ show createdWallet
