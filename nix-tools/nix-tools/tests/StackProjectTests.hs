{-# LANGUAGE LambdaCase #-}

-- | Self-contained tests for 'findCabalFiles' from the stack path.  These only
-- touch a temporary directory (no external tools, no network, no extra test
-- framework), so unlike the golden @tests@ suite they run in a plain build.
--
-- Regression coverage for #626 / #767: when a package directory contains both a
-- committed @.cabal@ file and a @package.yaml@, 'UsePackageYamlFirst' must
-- prefer the committed @.cabal@ rather than re-rendering through hpack.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.IORef (modifyIORef', newIORef, readIORef)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO.Extra (withTempDir)

import Cabal2Nix (CabalFile(..))
import Stack2nix.CLI (HpackUse(..))
import Stack2nix.Project (findCabalFiles)

-- A minimal, valid package.yaml (hpack input) and a committed .cabal that
-- deliberately disagree with it, so we can tell which one was picked.
packageYaml :: String
packageYaml = unlines
  [ "name: foo"
  , "version: 9.9.9"
  ]

committedCabal :: String
committedCabal = unlines
  [ "cabal-version: 2.4"
  , "name: foo"
  , "version: 1.0.0"
  , "library"
  , "  default-language: Haskell2010"
  ]

-- A crude, dependency-free description used both for assertions and messages.
describe :: CabalFile -> String
describe = \case
  OnDisk fp       -> "OnDisk " ++ fp
  InMemory _ fp _ -> "InMemory " ++ fp

-- Just the constructor name, for assertions that shouldn't depend on the exact
-- (hpack-derived) file path.
constructorOf :: CabalFile -> String
constructorOf = \case
  OnDisk{}   -> "OnDisk"
  InMemory{} -> "InMemory"

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let check name expected actual =
        unless (actual == expected) $ do
          putStrLn $ "FAIL: " ++ name
          putStrLn $ "  expected: " ++ show expected
          putStrLn $ "  actual:   " ++ show actual
          modifyIORef' failures (+ 1)
      inTmp files k = withTempDir $ \dir -> do
        forM_ files $ \(fname, contents) -> writeFile (dir </> fname) contents
        k dir

  -- #626/#767: committed .cabal wins over package.yaml.
  inTmp [("foo.cabal", committedCabal), ("package.yaml", packageYaml)] $ \dir -> do
    cfs <- findCabalFiles UsePackageYamlFirst dir
    check "prefers committed .cabal when both files exist"
      ["OnDisk " ++ (dir </> "foo.cabal")] (map describe cfs)

  -- Only package.yaml -> hpack (in-memory) is still used.
  inTmp [("package.yaml", packageYaml)] $ \dir -> do
    cfs <- findCabalFiles UsePackageYamlFirst dir
    check "renders via hpack when only package.yaml exists"
      ["InMemory"] (map constructorOf cfs)

  -- Only a .cabal -> used as-is.
  inTmp [("foo.cabal", committedCabal)] $ \dir -> do
    cfs <- findCabalFiles UsePackageYamlFirst dir
    check "uses the .cabal when only a .cabal exists"
      ["OnDisk " ++ (dir </> "foo.cabal")] (map describe cfs)

  -- IgnorePackageYaml ignores package.yaml even when present.
  inTmp [("foo.cabal", committedCabal), ("package.yaml", packageYaml)] $ \dir -> do
    cfs <- findCabalFiles IgnorePackageYaml dir
    check "IgnorePackageYaml uses only the .cabal even with both present"
      ["OnDisk " ++ (dir </> "foo.cabal")] (map describe cfs)

  n <- readIORef failures
  if n == 0
    then putStrLn "All findCabalFiles tests passed."
    else putStrLn (show n ++ " test(s) failed.") >> exitFailure
