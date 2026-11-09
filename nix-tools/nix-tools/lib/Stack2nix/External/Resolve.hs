module Stack2nix.External.Resolve
  ( resolveSnapshot
  , mergeDependencies
  , dependencyPackageName
  ) where

import Control.Monad (unless)
import Data.Aeson
import Data.Yaml hiding (Parser)
import Control.Applicative ((<|>))
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import System.FilePath ((</>), dropFileName)

import qualified Data.ByteString.Lazy.Char8 as L8

import Network.HTTP.Client
import Network.HTTP.Client.TLS
import           Network.HTTP.Types.Status  (ok200)
import Control.Exception.Base (SomeException(..),PatternMatchFail(..))

import Distribution.Types.PackageId (PackageIdentifier(..))
import Distribution.Types.PackageName (PackageName)

import Stack2nix.Stack (Stack(..), StackSnapshot(..), Dependency(..))

-- | A @resolver@ value in a stack.yaml file may point to an URL. As such
-- we need to be able to fetch one.
decodeURLEither :: FromJSON a => String -> IO (Either ParseException a)
decodeURLEither url
  | not (("http://" `isPrefixOf` url) || ("https://" `isPrefixOf` url))
  = return . Left . OtherParseException . SomeException . PatternMatchFail $ "No http or https prefix"
  | otherwise = do
      manager <- newManager tlsManagerSettings
      request <- parseRequest url
      response <- httpLbs request manager
      unless (ok200 == responseStatus response) $ error ("failed to download " ++ url)
      return . decodeEither' . L8.toStrict $ responseBody response


-- | If a stack.yaml file contains a @resolver@ that points to
-- a file, resolve that file and merge the snapshot into the
-- @Stack@ record.
resolveSnapshot :: FilePath -> Stack -> IO Stack
resolveSnapshot stackYaml stack@(Stack resolver compiler pkgs flags ghcOptions)
  = if ".yaml" `isSuffixOf` resolver
    then do evalue <- if ("http://" `isPrefixOf` resolver) || ("https://" `isPrefixOf` resolver)
                      then decodeURLEither resolver
                      else decodeFileEither (srcDir </> resolver)
            case evalue of
              Left e -> error (show e)
              Right (Snapshot resolver' compiler' _name pkgs' flags' ghcOptions') ->
                pure $ Stack resolver' (compiler' <|> compiler)
                    (mergeDependencies pkgs pkgs') (flags <> flags')
                    (ghcOptions <> ghcOptions')
    else pure stack
  where
    srcDir = dropFileName stackYaml

-- | Merge two dependency lists, giving precedence to the first (higher
-- priority) list. Stack resolves overlaps between the packages defined in a
-- @stack.yaml@ and those coming from a (custom) snapshot resolver with the
-- precedence: local packages > extra-deps > snapshot packages. In particular
-- an @extra-deps@ entry shadows a snapshot package of the same name rather
-- than being emitted twice (see haskell.nix issue #1690).
--
-- Here the higher priority list is the @stack.yaml@ dependencies (its
-- @packages@ followed by its @extra-deps@) and the lower priority list is the
-- snapshot's @packages@. When a package name is defined on both sides we keep
-- the higher priority definition and drop the lower priority duplicate.
--
-- Only 'PkgIndex' dependencies can be keyed by package name at this stage;
-- 'LocalPath' and 'DVCS' packages take their names from their @.cabal@ files,
-- which have not been read yet. Dependencies that cannot be keyed by name are
-- always kept, so genuine duplicates that are not a simple precedence
-- resolution are still reported later on.
--
-- With no overlapping names this is exactly @high '<>' low@, keeping the
-- common (no-duplicate) case byte-identical.
mergeDependencies :: [Dependency] -> [Dependency] -> [Dependency]
mergeDependencies high low = high ++ filter (not . shadowed) low
  where
    highNames = Set.fromList (mapMaybe dependencyPackageName high)
    shadowed dep = maybe False (`Set.member` highNames) (dependencyPackageName dep)

-- | The package name a dependency defines, when it can be determined without
-- reading a @.cabal@ file. Only package index ('PkgIndex') entries (plain
-- @name-version@ extra-deps and snapshot packages) qualify.
dependencyPackageName :: Dependency -> Maybe PackageName
dependencyPackageName (PkgIndex pkgId _) = Just (pkgName pkgId)
dependencyPackageName _                  = Nothing
