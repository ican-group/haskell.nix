{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Stack2nix.Stack
  ( Resolver
  , Name
  , Compiler
  , Sha256
  , CabalRev
  , URL
  , Rev
  , Stack(..)
  , Dependency(..)
  , Location(..)
  , StackSnapshot(..)
  , PackageFlags
  , GhcOptions
  , parsePackageIdentifier
  ) where

import Data.Char (isDigit)
import Data.List (isSuffixOf)
import qualified Data.Text as T
import Data.Aeson
import Control.Applicative ((<|>))
import Data.Monoid (mempty)

import Distribution.Types.PackageId
import Distribution.Pretty
import Distribution.Parsec
import Distribution.Compat.CharParsing
import Distribution.Parsec.FieldLineStream
import Distribution.Types.Version (nullVersion)

import qualified Data.HashMap.Strict as HM

--------------------------------------------------------------------------------
-- The stack.yaml file
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- packages
--
-- * (1) Paths
--   - ./site1
--   - ./site2
-- * (2) Git Locations
--   - location:
--       git: https://github.com/yesodweb/yesod
--       commit: 7038ae6317cb3fe4853597633ba7a40804ca9a46
--     extra-dep: true
--     subdirs:
--     - yesod-core
--     - yesod-bin

--------------------------------------------------------------------------------
-- extra-deps
--
-- * (1) Package index (optional sha of cabal files contents; or revision number)
--   - acme-missiles-0.3
--   - acme-missiles-0.3@sha256:2ba66a092a32593880a87fb00f3213762d7bca65a687d45965778deb8694c5d1
--   - acme-missiles-0.3@rev:0
--
-- * (2) Local File Path (foo-1.2.3 would be parsed as a package index)
--   - vendor/somelib
--   - ./foo-1.2.3
--
-- * (3) Git and Mercurial repos (optional subdirs; or github)
--   - git: git@github.com:commercialhaskell/stack.git
--     commit: 6a86ee32e5b869a877151f74064572225e1a0398
--   - git: git@github.com:snoyberg/http-client.git
--     commit: "a5f4f3"
--   - hg: https://example.com/hg/repo
--     commit: da39a3ee5e6b4b0d3255bfef95601890afd80709
--   - git: git@github.com:yesodweb/wai
--     commit: 2f8a8e1b771829f4a8a77c0111352ce45a14c30f
--     subdirs:
--     - auto-update
--     - wai
--   - github: snoyberg/http-client
--     commit: a5f4f30f01366738f913968163d856366d7e0342
--
-- * (4) Archives (HTTP(S) or local filepath)
--   - https://example.com/foo/bar/baz-0.0.2.tar.gz
--   - archive: http://github.com/yesodweb/wai/archive/2f8a8e1b771829f4a8a77c0111352ce45a14c30f.zip
--     subdirs:
--     - wai
--     - warp
--   - archive: ../acme-missiles-0.3.tar.gz
--     sha256: e563d8b524017a06b32768c4db8eff1f822f3fb22a90320b7e414402647b735b

-- NOTE: We will only parse a suitable subset of the stack.yaml file.

--------------------------------------------------------------------------------
-- Some generic types
type Resolver = String
type Name     = String
type Compiler = String
type Sha256   = String
newtype CabalRev = CabalRev Int -- cabal revision 0,1,2,...
 deriving (Show)
type URL      = String -- Git/Hg/... URL
type Rev      = String -- Git revision

instance Pretty CabalRev where
  pretty (CabalRev rev) = "r" <> pretty rev

instance Parsec CabalRev where
  parsec = char 'r' *> (CabalRev <$> integral)

--------------------------------------------------------------------------------
-- Data Types
-- Dependencies are the merged set of packages and extra-deps.
-- As we do not distinguish them in the same way stack does, we
-- can get away with this.
data Dependency
  = PkgIndex PackageIdentifier (Maybe (Either Sha256 CabalRev)) -- ^ overridden package in the stackage index
  | LocalPath String -- ^ Some local package (potentially overriding a package in the index as well)
  | DVCS Location (Maybe Sha256) [FilePath] -- ^ One or more packages fetched from git or similar.
  -- TODO: Support archives.
  -- | Archive ...
  deriving (Show)

-- flags are { pkg -> { flag -> bool } }
type PackageFlags = HM.HashMap T.Text (HM.HashMap T.Text Bool)

type GhcOptions = HM.HashMap T.Text T.Text

data Stack
  = Stack Resolver (Maybe Compiler) [Dependency] PackageFlags GhcOptions
  deriving (Show)

-- stack supports custom snapshots
-- https://docs.haskellstack.org/en/stable/custom_snapshot/
data StackSnapshot
  = Snapshot
    Resolver                  -- lts-XX.YY/nightly-...
    (Maybe Compiler)          -- possible compiler override for the snapshot
    Name                      -- name
    [Dependency]              -- packages
    PackageFlags              -- flags
    -- [PackageName]          -- drop-packages
    -- [PackageName -> Bool]  -- hidden
    GhcOptions                -- ghc-options
    deriving (Show)

data Location
  = Git URL Rev
  | HG  URL Rev
  deriving (Show)

--------------------------------------------------------------------------------
-- Parsers for package indices
sha256Suffix :: ParsecParser Sha256
sha256Suffix = string "@sha256:" *> some (satisfy (`elem` (['0'..'9']++['a'..'z']++['A'..'Z'])))
                                 -- Stack supports optional cabal file size after revision's SHA value,
                                 -- we parse it but it doesn't get used
                                 <* optional (char ',' <* some (satisfy isDigit))

revSuffix :: ParsecParser CabalRev
revSuffix = string "@rev:" *> (CabalRev . read <$> some (satisfy (`elem` ['0'..'9'])))

suffix :: ParsecParser (Maybe (Either Sha256 CabalRev))
suffix = option Nothing (Just <$> (try (Left <$> sha256Suffix) <|> (Right <$> revSuffix)))

pkgIndex :: ParsecParser Dependency
pkgIndex = PkgIndex <$> parsec <*> suffix <* eof

parsePackageIdentifier :: String -> Maybe (PackageIdentifier, Maybe (Either Sha256 CabalRev))
parsePackageIdentifier input =
  case runParsecParser pkgIndex "<parsePackageIdentifier>" (fieldLineStreamFromString input) of
    Right (PkgIndex d rev) -> Just (d, rev)
    _ -> Nothing

--------------------------------------------------------------------------------
-- JSON/YAML destructors

instance FromJSON Location where
  parseJSON = withObject "Location" $ \l ->
    parseGitHub l <|> parseGit l
    where
      parseGit l = Git
        <$> l .: "git"
        <*> l .: "commit"
      parseGitHub l = Git
        <$> do gitHubUrl <$> l .: "github"
        <*> l .: "commit"
      gitHubUrl ownerRepo =
        "https://github.com/" <> ownerRepo <> ".git"

instance FromJSON Stack where
  parseJSON = withObject "Stack" $ \s -> Stack
    -- `snapshot` is the modern synonym for `resolver` (stack >= 2.15.1).
    <$> (s .: "resolver" <|> s .: "snapshot")
    <*> s .:? "compiler" .!= Nothing
    <*> ((<>) <$> s .:? "packages"   .!= [LocalPath "."]
              <*> s .:? "extra-deps" .!= [])
    <*> s .:? "flags" .!= mempty
    <*> s .:? "ghc-options" .!= mempty

instance FromJSON StackSnapshot where
  parseJSON = withObject "Snapshot" $ \s -> Snapshot
    <$> (s .: "resolver" <|> s .: "snapshot")
    <*> s .:? "compiler" .!= Nothing
    -- `name` is optional for custom snapshots (stack itself does not require
    -- it) and stack-to-nix discards it anyway (bound as `_name` in
    -- Stack2nix.External.Resolve.resolveSnapshot), so default it rather than
    -- fail parsing with `key "name" not found` (see #1678, #1157).
    <*> s .:? "name" .!= "custom-snapshot"
    <*> s .:? "packages" .!= []
    <*> s .:? "flags" .!= mempty
    <*> s .:? "ghc-options" .!= mempty

instance FromJSON Dependency where
  -- Note: we will parse foo-X.Y.Z as a package.
  --       if we want it to be a localPath, it needs
  --       to be ./foo-X.Y.Z
  parseJSON p = parsePkgIndex p <|> parseLocalPath p <|> parseDVCS p
    where parsePkgIndex = withText "Package Index" $ \pi ->
            case parsePackageIdentifier (T.unpack pi) of
              -- Cabal will happily parse "foo" as a packageIdentifier,
              -- we however are only interested in those that have a version
              -- as well. Any valid version is larger than @nullVersion@, as
              -- such we can use that as a filter.
              (Just (pkgIdent, s)) | pkgVersion pkgIdent > nullVersion -> return $ PkgIndex pkgIdent s
              _ -> fail $ "invalid package index: " ++ show pi
          parseLocalPath = withText "Local Path" $
            return . LocalPath . dropTrailingSlash . T.unpack
          parseSubdirs o = do
            subdir' <- o .:? "subdir"
            let subdir = fmap (\d -> [d]) subdir'
            subdirs <- o .:? "subdirs"
            return (subdir <|> subdirs)
          parseDVCS = withObject "DVCS" $ \o -> DVCS
            <$> (o .: "location" <|> parseJSON p)
            <*> o .:? "nix-sha256" .!= Nothing
            <*> parseSubdirs o .!= ["."]

          -- drop trailing slashes. Nix doesn't like them much;
          -- stack doesn't seem to care.
          dropTrailingSlash p | "/" `isSuffixOf` p = take (length p - 1) p
          dropTrailingSlash p = p
