{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}

{-# OPTIONS_HADDOCK hide #-}
{-# OPTIONS_GHC -fno-warn-deprecations #-}

module Command.Address.Bootstrap
    ( Cmd
    , mod
    , run
    ) where

import Prelude hiding
    ( mod )

import Cardano.Address
    ( AddressDiscrimination (..), NetworkDiscriminant, base58 )
import Cardano.Address.Derivation
    ( XPub )
import Cardano.Address.Style.Byron
    ( Byron )
import Options.Applicative
    ( CommandFields
    , Mod
    , command
    , footerDoc
    , header
    , helper
    , info
    , optional
    , progDesc
    )
import Options.Applicative.Derivation
    ( DerivationPath, castDerivationPath, derivationPathOpt, xpubArg )
import Options.Applicative.Discrimination
    ( NetworkTag (..), networkTagOpt )
import Options.Applicative.Help.Pretty
    ( bold, indent, string, vsep )
import Options.Applicative.Style
    ( Style (..) )
import System.IO
    ( stdin, stdout )
import System.IO.Extra
    ( hGetXPub, progName )

import qualified Cardano.Address.Style.Byron as Byron
import qualified Cardano.Address.Style.Icarus as Icarus
import qualified Data.ByteString.Char8 as B8
import qualified Data.Text.Encoding as T


data Cmd = Cmd
    { rootXPub :: Maybe XPub
    , derivationPath :: Maybe DerivationPath
    , networkTag :: NetworkTag
    } deriving (Show)

mod :: (Cmd -> parent) -> Mod CommandFields parent
mod liftCmd = command "bootstrap" $
    info (helper <*> fmap liftCmd parser) $ mempty
        <> progDesc "Create a bootstrap address"
        <> header "Those addresses, now deprecated, were used during the Byron era."
        <> footerDoc (Just $ vsep
            [ string "Example:"
            , indent 2 $ bold $ string $ "$ "<>progName<>" recovery-phrase generate --size 12 \\"
            , indent 4 $ bold $ string $ "| "<>progName<>" key from-recovery-phrase Byron > root.prv"
            , indent 2 $ string ""
            , indent 2 $ bold $ string "$ cat root.prv \\"
            , indent 4 $ bold $ string $ "| "<>progName<>" key child 14H/42H > addr.prv"
            , indent 4 $ bold $ string $ "| "<>progName<>" key public \\"
            , indent 4 $ bold $ string $ "| "<>progName<>" address bootstrap $(cat root.prv | "<>progName<>" key public) \\"
            , indent 8 $ bold $ string "--network-tag 764824073 --path 14H/42H"
            , indent 2 $ string "DdzFFzCqrht2KG1vWt5WGhVC9Ezyu32RgB5M2DocdZ6BQU6zj69LSqksDmdM..."
            ])
  where
    parser = Cmd
        <$> optional (xpubArg "A root public key. Needed for Byron addresses only.")
        <*> optional derivationPathOpt
        <*> networkTagOpt Byron

run :: Cmd -> IO ()
run Cmd{networkTag,rootXPub,derivationPath} = do
    xpub <- hGetXPub stdin
    addr <- case derivationPath of
        Nothing ->
            pure $ Icarus.paymentAddress discriminant (Icarus.liftXPub xpub)
        Just untypedPath -> do
            root <- maybe
                (fail "A root public key must be provided when --path is provided") pure rootXPub
            case castDerivationPath untypedPath of
                [acctIx, addrIx] -> do
                    let path = (acctIx, toEnum (fromEnum addrIx))
                    let xkey = Byron.liftXPub root path xpub
                    pure $ Byron.paymentAddress discriminant xkey
                _ -> do
                    fail "Byron derivation path must describe 2 levels (e.g. 0H/0H)"
    B8.hPutStr stdout $ T.encodeUtf8 $ base58 addr
  where
    discriminant :: NetworkDiscriminant Byron -- Or Icarus, same.
    discriminant
        | networkTag == snd Byron.byronMainnet =
            Byron.byronMainnet
        | otherwise =
            (RequiresNetworkTag, networkTag)