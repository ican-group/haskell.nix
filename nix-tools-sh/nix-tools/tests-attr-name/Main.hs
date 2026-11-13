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
  putStrLn "non-identifier cabal names are quoted in generated Nix (OK)"
 where
  die' :: String -> Text -> IO ()
  die' msg rendered = do
    hPutStrLn stderr ("tests-attr-name: " ++ msg ++ "\nrendered:\n" ++ T.unpack rendered)
    exitFailure
