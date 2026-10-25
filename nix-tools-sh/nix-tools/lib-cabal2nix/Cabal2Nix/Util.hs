{-# LANGUAGE OverloadedStrings #-}
module Cabal2Nix.Util where

import System.Directory
import System.FilePath

import Control.Monad
import Data.String (IsString)

import Data.ByteString.Char8 (pack, unpack)
import Crypto.Hash.SHA256 (hash)
import qualified Data.ByteString.Base16 as Base16

import Data.List.NonEmpty (NonEmpty)
import Data.Fix(Fix(..))
import Nix.Expr

listDirectories :: FilePath -> IO [FilePath]
listDirectories p =
  filter (/= ".git") <$> listDirectory p
  >>= filterM (doesDirectoryExist . (p </>))

quoted :: (IsString a, Semigroup a) => a -> a
quoted str = "\"" <> str <> "\""

selectOr :: NExpr -> NAttrPath NExpr -> NExpr -> NExpr
selectOr obj path alt = Fix (NSelect (Just $ alt) obj path)

mkThrow :: NExpr -> NExpr
mkThrow msg = (mkSym "builtins" @. "throw") @@ msg

sha256 :: String -> String
sha256 = unpack . Base16.encode . hash . pack

bindPath :: NonEmpty VarName -> NExpr -> Binding NExpr
bindPath ks e = NamedVar (fmap StaticKey ks) e nullPos
