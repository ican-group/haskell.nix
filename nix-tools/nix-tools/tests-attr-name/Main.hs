{-# LANGUAGE OverloadedStrings #-}

-- | Regression test for issue #2572: cabal allows flag (and package/component)
-- names that are not valid Nix identifiers, e.g. the flag @3d@ in hgg. The
-- generated Nix must quote them (@"3d" = false;@, @flags."3d"@) or it fails to
-- parse. Names that are already identifiers must stay bare so that existing
-- generated files (hackage.nix) do not change.
module Main (main) where

import           Cabal2Nix                    (CabalDetailLevel (..), CabalFile (..), cabal2nix)
import           Cabal2Nix.Util               (attrName)
import           Control.Monad                (unless)
import qualified Data.HashMap.Strict          as HM
import qualified Data.HashSet                 as HS
import           Nix.Expr                     (VarName (..))
import           Plan2Nix                     (plan2nix)
import           Plan2Nix.CLI                 (Args (..), HpackUse (..))
import           Plan2Nix.Plan                (Package (..), Plan (..))
import qualified Data.ByteString.Char8        as BS
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import           Nix.Parser                   (parseNixText)
import           Nix.Pretty                   (prettyNix)
import           Prettyprinter                (defaultLayoutOptions, layoutPretty)
import           Prettyprinter.Render.Text    (renderStrict)
import           System.Exit                  (exitFailure)
import           System.IO                    (hPutStrLn, stderr)

cabalFile :: BS.ByteString
cabalFile = BS.unlines
  [ "cabal-version: 2.4"
  , "name: hgg-like"
  , "version: 0.1"
  , "flag 3d"
  , "  default: False"
  , "flag png"
  , "  default: True"
  , "library"
  , "  build-depends: base"
  , "  if flag(3d)"
  , "    build-depends: containers"
  , "  if flag(png)"
  , "    build-depends: bytestring"
  ]

main :: IO ()
main = do
  -- attrName itself
  let cases = [ ("png", "png"), ("with-dash", "with-dash"), ("_x'", "_x'")
              , ("3d", "\"3d\""), ("-x", "\"-x\""), ("a.b", "\"a.b\"")
              , ("if", "if") -- keywords are quoted by hnix's pretty-printer
              ]
      bad = [ (i, o, attrName i) | (i, o) <- cases, attrName i /= o ]
  unless (null bad) $ die' ("attrName: " ++ show bad) ""

  expr <- cabal2nix False MinimalDetails Nothing (InMemory Nothing "hgg-like.cabal" cabalFile)
  let rendered = renderStrict (layoutPretty defaultLayoutOptions (prettyNix expr))
      needles = [ "\"3d\" = false", "flags.\"3d\"", "png = true", "flags.png" ]
      missing = filter (not . (`T.isInfixOf` rendered)) needles
  unless (null missing) $ die' ("missing " ++ show missing) rendered
  case parseNixText rendered of
    Left err -> die' ("generated Nix does not parse: " ++ show err) rendered
    Right _  -> pure ()

  -- plan-to-nix: plan.json flag and package names go through the same
  -- quoting (`hgg.flags."3d"`, `"3d-graphics".revision`).
  let pkg flags = Just Package
        { packageVersion = "0.1", packageFlags = HM.fromList flags
        , packageSrc = Nothing, packageHasDescriptionOverride = False
        , packagePreExisting = False }
      plan = Plan
        { packages = HM.fromList
            [ ("hgg", pkg [(VarName "3d", False), (VarName "png", True)])
            , ("3d-graphics", pkg []) ]
        , extras = HM.empty, components = HS.empty
        , compilerVersion = "9.6.7", compilerPackages = HM.empty }
      args = Args { argOutputDir = ".", argPlanJSON = "plan.json"
                  , argCabalProject = "cabal.project", argCacheFile = ".nix-tools.cache"
                  , argDetailLevel = MinimalDetails, argHpackUse = IgnorePackageYaml }
  planExpr <- plan2nix args plan
  let planRendered = renderStrict (layoutPretty defaultLayoutOptions (prettyNix planExpr))
      planNeedles = [ "hgg.flags.\"3d\" = false", "hgg.flags.png = true"
                    , "\"3d-graphics\".revision", "hackage.\"3d-graphics\"" ]
      planMissing = filter (not . (`T.isInfixOf` planRendered)) planNeedles
  unless (null planMissing) $ die' ("plan-to-nix: missing " ++ show planMissing) planRendered
  case parseNixText planRendered of
    Left err -> die' ("plan-to-nix output does not parse: " ++ show err) planRendered
    Right _  -> pure ()
  putStrLn "non-identifier cabal names are quoted in generated Nix (OK)"
 where
  die' :: String -> Text -> IO ()
  die' msg rendered = do
    hPutStrLn stderr ("tests-attr-name: " ++ msg ++ "\nrendered:\n" ++ T.unpack rendered)
    exitFailure
