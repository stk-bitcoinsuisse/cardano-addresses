{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Copyright: © 2018-2020 IOHK
-- License: Apache-2.0
--
-- Implementation of address derivation for the random scheme, as
-- implemented by the Icarus wallet.
--
-- For full documentation of the key derivation schemes,
-- see the "Cardano.Crypto.Wallet" module, and the implementation in
-- <https://github.com/input-output-hk/cardano-crypto/blob/4590efa638397e952a51a8994b5543e4ea3c1ecd/cbits/encrypted_sign.c cardano-crypto>.

module Cardano.AddressDerivation.Icarus
    ( -- * Types
      Icarus (..)

      -- * Generation
    , unsafeGenerateKeyFromHardwareLedger
    , unsafeGenerateKeyFromSeed
    , minSeedLengthBytes

    ) where

import Prelude

import Cardano.AddressDerivation
    ( Depth (..)
    , DerivationType (..)
    , GenMasterKey (..)
    , HardDerivation (..)
    , Index (..)
    , SoftDerivation (..)
    )
import Cardano.Crypto.Wallet
    ( DerivationScheme (..)
    , XPrv
    , deriveXPrv
    , deriveXPub
    , generateNew
    , xPrvChangePass
    , xprv
    )
import Cardano.Mnemonic
    ( SomeMnemonic (..), entropyToBytes, mnemonicToEntropy, mnemonicToText )
import Control.Arrow
    ( first, left )
import Control.DeepSeq
    ( NFData )
import Control.Exception.Base
    ( assert )
import Crypto.Error
    ( eitherCryptoError )
import Crypto.Hash.Algorithms
    ( SHA256 (..), SHA512 (..) )
import Crypto.MAC.HMAC
    ( HMAC, hmac )
import Data.Bits
    ( clearBit, setBit, testBit )
import Data.ByteArray
    ( ScrubbedBytes )
import Data.ByteString
    ( ByteString )
import Data.Function
    ( (&) )
import Data.Maybe
    ( fromMaybe )
import Data.Word
    ( Word32 )
import GHC.Generics
    ( Generic )

import qualified Crypto.ECC.Edwards25519 as Ed25519
import qualified Crypto.KDF.PBKDF2 as PBKDF2
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

{-------------------------------------------------------------------------------
                                   Key Types
-------------------------------------------------------------------------------}
-- | A cryptographic key for sequential-scheme address derivation, with
-- phantom-types to disambiguate key types.
--
-- @
-- let rootPrivateKey = Icarus 'RootK XPrv
-- let accountPubKey = Icarus 'AccountK XPub
-- let addressPubKey = Icarus 'AddressK XPub
-- @
newtype Icarus (depth :: Depth) key =
    Icarus { getKey :: key }
    deriving stock (Generic, Show, Eq)

instance (NFData key) => NFData (Icarus depth key)

instance GenMasterKey Icarus where
    type GenMasterKeyFrom Icarus = SomeMnemonic

    genMasterKey = unsafeGenerateKeyFromSeed

instance HardDerivation Icarus where
    type AccountIndexDerivationType Icarus = 'Hardened
    type AddressIndexDerivationType Icarus = 'Soft

    deriveAccountPrivateKey pwd (Icarus rootXPrv) (Index accIx) =
        let
            purposeXPrv = -- lvl1 derivation; hardened derivation of purpose'
                deriveXPrv DerivationScheme2 pwd rootXPrv purposeIndex
            coinTypeXPrv = -- lvl2 derivation; hardened derivation of coin_type'
                deriveXPrv DerivationScheme2 pwd purposeXPrv coinTypeIndex
            acctXPrv = -- lvl3 derivation; hardened derivation of account' index
                deriveXPrv DerivationScheme2 pwd coinTypeXPrv accIx
        in
            Icarus acctXPrv

    deriveAddressPrivateKey pwd (Icarus accXPrv) accountingStyle (Index addrIx) =
        let
            changeCode =
                fromIntegral $ fromEnum accountingStyle
            changeXPrv = -- lvl4 derivation; soft derivation of change chain
                deriveXPrv DerivationScheme2 pwd accXPrv changeCode
            addrXPrv = -- lvl5 derivation; soft derivation of address index
                deriveXPrv DerivationScheme2 pwd changeXPrv addrIx
        in
            Icarus addrXPrv

instance SoftDerivation Icarus where
    deriveAddressPublicKey (Icarus accXPub) accountingStyle (Index addrIx) =
        fromMaybe errWrongIndex $ do
            let changeCode = fromIntegral $ fromEnum accountingStyle
            changeXPub <- -- lvl4 derivation in bip44 is derivation of change chain
                deriveXPub DerivationScheme2 accXPub changeCode
            addrXPub <- -- lvl5 derivation in bip44 is derivation of address chain
                deriveXPub DerivationScheme2 changeXPub addrIx
            return $ Icarus addrXPub
      where
        errWrongIndex = error $
            "deriveAddressPublicKey failed: was given an hardened (or too big) \
            \index for soft path derivation ( " ++ show addrIx ++ "). This is \
            \either a programmer error, or, we may have reached the maximum \
            \number of addresses for a given wallet."

{-------------------------------------------------------------------------------
                                 Key generation
-------------------------------------------------------------------------------}

-- | Purpose is a constant set to 44' (or 0x8000002C) following the original
-- BIP-44 specification.
--
-- It indicates that the subtree of this node is used according to this
-- specification.
--
-- Hardened derivation is used at this level.
purposeIndex :: Word32
purposeIndex = 0x8000002C

-- | One master node (seed) can be used for unlimited number of independent
-- cryptocoins such as Bitcoin, Litecoin or Namecoin. However, sharing the
-- same space for various cryptocoins has some disadvantages.
--
-- This level creates a separate subtree for every cryptocoin, avoiding reusing
-- addresses across cryptocoins and improving privacy issues.
--
-- Coin type is a constant, set for each cryptocoin. For Cardano this constant
-- is set to 1815' (or 0x80000717). 1815 is the birthyear of our beloved Ada
-- Lovelace.
--
-- Hardened derivation is used at this level.
coinTypeIndex :: Word32
coinTypeIndex = 0x80000717

-- | The minimum seed length for 'generateKeyFromSeed' and 'unsafeGenerateKeyFromSeed'.
minSeedLengthBytes :: Int
minSeedLengthBytes = 16

-- | Hardware Ledger devices generates keys from mnemonic using a different
-- approach (different from the rest of Cardano).
--
-- It is a combination of:
--
-- - [SLIP 0010](https://github.com/satoshilabs/slips/blob/master/slip-0010.md)
-- - [BIP 0032](https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki)
-- - [BIP 0039](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki)
-- - [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.1.5)
-- - What seems to be arbitrary changes from Ledger regarding the calculation of
--   the initial chain code and generation of the root private key.
unsafeGenerateKeyFromHardwareLedger
    :: SomeMnemonic
        -- ^ The root mnemonic
    -> ScrubbedBytes
        -- ^ Master encryption passphrase
    -> Icarus 'RootK XPrv
unsafeGenerateKeyFromHardwareLedger (SomeMnemonic mw) pwd = unsafeFromRight $ do
    let seed = pbkdf2HmacSha512
            $ T.encodeUtf8
            $ T.intercalate " "
            $ mnemonicToText mw

    -- NOTE
    -- SLIP-0010 refers to `iR` as the chain code. Here however, the chain code
    -- is obtained as a hash of the initial seed whereas iR is used to make part
    -- of the root private key itself.
    let cc = hmacSha256 (BS.pack [1] <> seed)
    let (iL, iR) = first pruneBuffer $ hashRepeatedly seed
    pA <- ed25519ScalarMult iL

    prv <- left show $ xprv $ iL <> iR <> pA <> cc
    pure $ Icarus (xPrvChangePass (mempty :: ByteString) pwd prv)
  where
    -- Errors yielded in the body of 'unsafeGenerateKeyFromHardwareLedger' are
    -- programmer errors (out-of-range byte buffer access or, invalid length for
    -- cryptographic operations). Therefore, we throw badly if we encounter any.
    unsafeFromRight :: Either String a -> a
    unsafeFromRight = either error id

    -- This is the algorithm described in SLIP 0010 for master key generation
    -- with an extra step to discard _some_ of the potential private keys. Why
    -- this extra step remains a mystery as of today.
    --
    --      1. Generate a seed byte sequence S of 512 bits according to BIP-0039.
    --         (done in a previous step, passed as argument).
    --
    --      2. Calculate I = HMAC-SHA512(Key = "ed25519 seed", Data = S)
    --
    --      3. Split I into two 32-byte sequences, IL and IR.
    --
    -- extra *******************************************************************
    -- *                                                                       *
    -- *    3.5 If the third highest bit of the last byte of IL is not zero    *
    -- *        S = I and go back to step 2.                                   *
    -- *                                                                       *
    -- *************************************************************************
    --
    --      4. Use parse256(IL) as master secret key, and IR as master chain code.
    hashRepeatedly :: ByteString -> (ByteString, ByteString)
    hashRepeatedly bytes = case BS.splitAt 32 (hmacSha512 bytes) of
        (iL, iR) | isInvalidKey iL -> hashRepeatedly (iL <> iR)
        (iL, iR) -> (iL, iR)
      where
        isInvalidKey k = testBit (k `BS.index` 31) 5

    -- - Clear the lowest 3 bits of the first byte
    -- - Clear the highest bit of the last byte
    -- - Set the second highest bit of the last byte
    --
    -- As described in [RFC 8032 - 5.1.5](https://tools.ietf.org/html/rfc8032#section-5.1.5)
    pruneBuffer :: ByteString -> ByteString
    pruneBuffer bytes =
        let
            (firstByte, rest) = fromMaybe (error "pruneBuffer: no first byte") $
                BS.uncons bytes

            (rest', lastByte) = fromMaybe (error "pruneBuffer: no last byte") $
                BS.unsnoc rest

            firstPruned = firstByte
                & (`clearBit` 0)
                & (`clearBit` 1)
                & (`clearBit` 2)

            lastPruned = lastByte
                & (`setBit` 6)
                & (`clearBit` 7)
        in
            (firstPruned `BS.cons` BS.snoc rest' lastPruned)

    ed25519ScalarMult :: ByteString -> Either String ByteString
    ed25519ScalarMult bytes = do
        scalar <- left show $ eitherCryptoError $ Ed25519.scalarDecodeLong bytes
        pure $ Ed25519.pointEncode $ Ed25519.toPoint scalar

    -- As described in [BIP 0039 - From Mnemonic to Seed](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki#from-mnemonic-to-seed)
    pbkdf2HmacSha512 :: ByteString -> ByteString
    pbkdf2HmacSha512 bytes = PBKDF2.generate
        (PBKDF2.prfHMAC SHA512)
        (PBKDF2.Parameters 2048 64)
        bytes
        ("mnemonic" :: ByteString)

    hmacSha256 :: ByteString -> ByteString
    hmacSha256 =
        BA.convert @(HMAC SHA256) . hmac salt

    -- As described in [SLIP 0010 - Master Key Generation](https://github.com/satoshilabs/slips/blob/master/slip-0010.md#master-key-generation)
    hmacSha512 :: ByteString -> ByteString
    hmacSha512 =
        BA.convert @(HMAC SHA512) . hmac salt

    salt :: ByteString
    salt = "ed25519 seed"

-- | Generate a new key from seed. Note that the @depth@ is left open so that
-- the caller gets to decide what type of key this is. This is mostly for
-- testing, in practice, seeds are used to represent root keys, and one should
-- use 'generateKeyFromSeed'.
unsafeGenerateKeyFromSeed
    :: SomeMnemonic
        -- ^ The root mnemonic
    -> ScrubbedBytes
        -- ^ Master encryption passphrase
    -> Icarus depth XPrv
unsafeGenerateKeyFromSeed (SomeMnemonic mw) pwd =
    let
        seed  = entropyToBytes $ mnemonicToEntropy mw
        seedValidated = assert
            (BA.length seed >= minSeedLengthBytes && BA.length seed <= 255)
            seed
    in Icarus $ generateNew seedValidated (mempty :: ByteString) pwd
