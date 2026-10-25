{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module StackRepos
  ( doStackRepos
  , stack2nix
  ) where

import Data.Aeson (ToJSON(..))
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as LBS (writeFile)
import Data.Yaml (decodeFileEither)

import GHC.Generics (Generic)

import Stack2nix.Stack (Stack(..), Dependency(..), Location(..))
import Stack2nix.External.Resolve

import StackRepos.CLI (Args(..))

data SourceRepos = SourceRepos
  { url     :: String
  , rev     :: String
  , sha256  :: Maybe String
  , subdirs :: [FilePath]
  } deriving (Show, Eq, Ord, Generic)

instance ToJSON SourceRepos

doStackRepos :: Args -> IO ()
doStackRepos args = do
  evalue <- decodeFileEither (argStackYaml args)
  case evalue of
    Left e -> error (show e)
    Right value -> stack2nix args
                    =<< resolveSnapshot (argStackYaml args) value

stack2nix :: Args -> Stack -> IO ()
stack2nix args (Stack _ _ pkgs _ _) =
  LBS.writeFile "repos.json" $ encodePretty (
    pkgs >>= (\case
       (DVCS (Git url rev) sha256 subdirs) ->
         [SourceRepos { url, rev, sha256, subdirs }]
       _ -> []))
