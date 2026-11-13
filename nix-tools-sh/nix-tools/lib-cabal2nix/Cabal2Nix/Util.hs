{-# LANGUAGE OverloadedStrings #-}
module Cabal2Nix.Util where

import System.Directory
import System.FilePath

import Control.Monad
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.String (IsString)
import Data.Text (Text)
import qualified Data.Text as T

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

-- | An attribute name for generated Nix: left bare when it is a valid Nix
-- identifier, double-quoted otherwise.  Cabal allows names that are not Nix
-- identifiers, e.g. the flag @3d@ in hgg, which must be written @"3d"@ (#2572).
-- Nix keywords are left bare too, hnix's pretty-printer quotes those itself.
attrName :: Text -> Text
attrName s = case T.uncons s of
  Just (c, cs)
    | (isAsciiLower c || isAsciiUpper c || c == '_')
      && T.all (\x -> isAsciiLower x || isAsciiUpper x || isDigit x || x `elem` ("_'-" :: String)) cs
    -> s
  _ -> quoted s

selectOr :: NExpr -> NAttrPath NExpr -> NExpr -> NExpr
selectOr obj path alt = Fix (NSelect (Just $ alt) obj path)

mkThrow :: NExpr -> NExpr
mkThrow msg = (mkSym "builtins" @. "throw") @@ msg

sha256 :: String -> String
sha256 = unpack . Base16.encode . hash . pack

bindPath :: NonEmpty VarName -> NExpr -> Binding NExpr
bindPath ks e = NamedVar (fmap StaticKey ks) e nullPos
