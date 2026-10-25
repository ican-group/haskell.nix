{-# LANGUAGE OverloadedStrings #-}

module Plan2Nix.Plan
  ( Version
  , Revision
  , URL
  , Rev
  , Plan(..)
  , PkgSrc(..)
  , Package(..)
  , Location(..)
  ) where


import           Data.Text                                ( Text )
import           Data.HashMap.Strict                      ( HashMap )
import           Data.HashSet                             ( HashSet )
import           Nix.Expr

type Version = Text
type Revision = Text -- Can be: rNUM, cabal file sha256, or "default"
-- See stack2nix
type URL = String
type Rev = String

data Location
  = Git URL Rev
  | HG  URL Rev
  deriving (Show)

data Plan = Plan
  { packages :: HashMap Text (Maybe Package)
  , extras :: HashMap Text (Maybe Package)
  , components :: HashSet Text
  , compilerVersion :: Text
  , compilerPackages :: HashMap Text (Maybe Version)
  } deriving (Show)


data PkgSrc
  = LocalPath FilePath -- ^ some local package (potentially overriding a package in the index as well)
  | DVCS Location [FilePath] -- ^ One or more packages fetched from git or similar
  deriving Show

data Package = Package
  { packageVersion :: Version
  , packageFlags :: HashMap VarName Bool
  , packageSrc :: Maybe PkgSrc
  , packageHasDescriptionOverride :: Bool
  , packagePreExisting :: Bool
  } deriving (Show)
