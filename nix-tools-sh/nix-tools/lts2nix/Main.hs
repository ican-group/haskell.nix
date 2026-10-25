{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import System.Environment (getArgs,lookupEnv)
import Data.Maybe (fromMaybe)

import Distribution.Pretty (pretty)

import Data.Yaml (decodeFileEither)

import Data.Text (Text)
import qualified Data.Text as Text

import Nix.Pretty (prettyNix)
import Nix.Expr

import           Data.Aeson
import qualified Data.Aeson.Key                as Key
import           Data.Aeson.KeyMap (KeyMap)
import qualified Data.Aeson.KeyMap             as KeyMap
import qualified Data.HashMap.Strict           as Map
import qualified Data.Vector                   as V
import           Lens.Micro
import           Lens.Micro.Aeson

import           Cabal2Nix.Plan

import           Stack2nix.Stack (parsePackageIdentifier)
import Distribution.Types.PackageId

type CompilerPackages = Map.HashMap Text (Map.HashMap Text Text)

main :: IO ()
main = getArgs >>= \case
  [file] -> do
    print . prettyNix =<< ltsPackages file
  _ -> putStrLn "call with /path/to/lts.yaml (Lts2Nix /path/to/lts-X.Y.yaml)"

ltsPackages :: FilePath -> IO NExpr
ltsPackages lts = do
  -- use yaml here, so we don't have to deal with yaml AND json.
  -- pull it from https://raw.githubusercontent.com/commercialhaskell/stackage-content/master/stack/global-hints.yaml
  cpYaml <- fromMaybe "./global-hints.yaml" <$> lookupEnv "GLOBAL_HINTS"
  compilerPackages <- decodeFileEither cpYaml >>= \case
    Left e      -> error $ "Parsing " ++ show cpYaml ++ ": " ++ show e
    Right value -> pure value
  evalue <- decodeFileEither lts
  case evalue of
    Left  e     -> error $ "Parsing " ++ show lts ++ ": " ++ show e
    Right value -> pure $ plan2nix $ lts2plan compilerPackages value

-- pretty crude hack to get the compiler version. Assuming ghc-X.Y.Z
parseCompilerVersion :: Text -> Text
parseCompilerVersion c
  | "ghc-" `Text.isPrefixOf` c = Text.drop 4 c
  | otherwise = error $ "Unable to parse version from compiler: " ++ Text.unpack c

lts2plan :: CompilerPackages -> Value -> Plan
lts2plan compilerPackagesMap lts = Plan { packages, compilerVersion, compilerPackages }
  where
    compilerName = lts ^. key "resolver" . key "compiler" . _String
    compilerVersion = parseCompilerVersion compilerName
    compilerPackages = Just <$> Map.lookupDefault (error $ "failed to lookup the compiler packages for compiler: " ++ Text.unpack compilerName) compilerName compilerPackagesMap
    compilerPackages' = fmap vrToPkg <$> compilerPackages
      where vrToPkg v = Package v Nothing Map.empty

    -- turn flags into HashMap Text (HashMap Text Bool)
    flags :: KeyMap (KeyMap Bool)
    flags = lts ^. key "flags" . _Object <&> (\v -> KeyMap.mapMaybe (^? _Bool) $ v ^. _Object)
    packages' = Map.fromList . V.toList $ lts ^. key "packages" . _Array <&> \v ->
      let (pkg, rev) = case (parsePackageIdentifier . Text.unpack $ v ^. key "hackage" . _String) of
                          Just p -> p
                          _ -> error $ "failed to parse: " ++ Text.unpack (v ^. key "hackage" . _String)
          name = Text.pack (show (pretty (pkgName pkg)))
      in (name, Just $ Package
        { packageVersion = Text.pack (show (pretty (pkgVersion pkg)))
        , packageRevision = case rev of
            Just (Left sha) -> Just $ Text.pack sha
            _               -> Nothing
        , packageFlags = Map.fromList . fmap (\(k, val) -> (VarName (Key.toText k), val))
            . KeyMap.toList . fromMaybe mempty $ KeyMap.lookup (Key.fromText name) flags
        })

    packages = packages' `Map.union` compilerPackages'
