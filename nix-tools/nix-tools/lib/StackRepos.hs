{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module StackRepos
  ( doStackRepos
  , stack2nix
  ) where

import Data.Aeson (ToJSON(..), object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as LBS (writeFile)
import Data.Yaml (decodeFileEither)

import GHC.Generics (Generic)

import Stack2nix.Stack (Stack(..), Dependency(..), Location(..), archiveCacheRev)
import Stack2nix.External.Resolve

import StackRepos.CLI (Args(..))

-- | A git repository, or (with @type = "archive"@) an archive.  For an
-- archive @rev@ is 'archiveCacheRev', @sha256@ is the @nix-sha256@ of the
-- unpacked tree and @archiveSha256@ is pantry's @sha256@ of the archive file.
-- Git entries are written exactly as before (no @type@ field), so older
-- consumers of @repos.json@ still read them.
data SourceRepos = SourceRepos
  { url     :: String
  , rev     :: String
  , sha256  :: Maybe String
  , subdirs :: [FilePath]
  } deriving (Show, Eq, Ord, Generic)

instance ToJSON SourceRepos

data ArchiveRepos = ArchiveRepos
  { url           :: String
  , rev           :: String
  , sha256        :: Maybe String
  , archiveSha256 :: Maybe String
  , subdirs       :: [FilePath]
  } deriving (Show, Eq, Ord, Generic)

instance ToJSON ArchiveRepos where
  toJSON ArchiveRepos{..} = object
    [ "type"          .= ("archive" :: String)
    , "url"           .= url
    , "rev"           .= rev
    , "sha256"        .= sha256
    , "archiveSha256" .= archiveSha256
    , "subdirs"       .= subdirs
    ]

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
         [toJSON SourceRepos { url, rev, sha256, subdirs }]
       (Archive url archiveSha256 sha256 subdirs) ->
         [toJSON ArchiveRepos { url, rev = archiveCacheRev, sha256, archiveSha256, subdirs }]
       _ -> []))
