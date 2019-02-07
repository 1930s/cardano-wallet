-- | UPDATE operations on HD wallets
module Cardano.Wallet.Kernel.DB.HdWallet.Update (
    updateHdRoot
  , updateHdRootPassword
  , updateHdAccountName
  , updateHdAccountGap
  ) where

import           Universum

import           Cardano.Wallet.Kernel.AddressPoolGap (AddressPoolGap)
import           Cardano.Wallet.Kernel.DB.HdRootId (HdRootId)
import           Cardano.Wallet.Kernel.DB.HdWallet
import           Cardano.Wallet.Kernel.DB.Util.AcidState
import           UTxO.Util (modifyAndGetNew)

{-------------------------------------------------------------------------------
  UPDATE
-------------------------------------------------------------------------------}

-- | Updates in one gulp the Hd Wallet name and assurance level.
updateHdRoot :: HdRootId
             -> AssuranceLevel
             -> WalletName
             -> Update' UnknownHdRoot HdWallets HdRoot
updateHdRoot rootId assurance name =
    zoomHdRootId identity rootId $ do
        modifyAndGetNew $ set hdRootAssurance assurance . set hdRootName name

updateHdRootPassword :: HdRootId
                     -> HasSpendingPassword
                     -> Update' UnknownHdRoot HdWallets HdRoot
updateHdRootPassword rootId hasSpendingPassword =
    zoomHdRootId identity rootId $ do
        modifyAndGetNew $ hdRootHasPassword .~ hasSpendingPassword

updateHdAccountName :: HdAccountId
                    -> AccountName
                    -> Update' UnknownHdAccount HdWallets HdAccount
updateHdAccountName accId name = do
    zoomHdAccountId identity accId $ do
        modifyAndGetNew $ hdAccountName .~ name

updateHdAccountGap :: HdAccountId
                   -> AddressPoolGap
                   -> Update' UpdateGapError HdWallets HdAccount
updateHdAccountGap accId gap =
    zoomHdAccountId embedErr accId $ do
        acc <- get
        case acc ^. hdAccountBase of
            HdAccountBaseEO _ pKey _ ->
                modifyAndGetNew $ hdAccountBase .~ HdAccountBaseEO accId pKey gap
            HdAccountBaseFO _ ->
                -- It's an error: we try to update a gap in account with FO-branch.
                throwError $ UpdateGapErrorFOAccount accId
  where
    embedErr :: UnknownHdAccount -> UpdateGapError
    embedErr (UnknownHdAccountRoot rootId) = UpdateGapErrorUnknownHdAccountRoot rootId
    embedErr (UnknownHdAccount accountId)  = UpdateGapErrorUnknownHdAccount accountId
