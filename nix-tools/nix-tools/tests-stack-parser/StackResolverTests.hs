{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the stack @resolver@/@snapshot@ field and for snapshot files in
-- the commercialhaskell/stackage-snapshots format (#1677).  Self-contained:
-- no external tools or network, so this suite is safe to run in CI without
-- the golden-test fixtures.
module Main (main) where

import Control.Exception (bracket_)
import Data.List (isInfixOf)
import qualified Data.ByteString.Char8 as B8
import qualified Data.HashMap.Strict as HM
import qualified Data.Yaml as Y
import Distribution.Pretty (prettyShow)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, assertFailure, assertBool, (@?=))

import Stack2nix.External.Resolve (resolveSnapshot)
import Stack2nix.Stack (Stack(..), StackSnapshot(..), Dependency(..))

-- Decode a YAML document, failing the test with the parse error otherwise.
decode :: Y.FromJSON a => String -> IO a
decode s = case Y.decodeEither' (B8.pack s) of
  Left e  -> assertFailure ("unexpected parse failure: " ++ show e) >> undefined
  Right a -> pure a

stackResolver :: Stack -> String
stackResolver (Stack r _ _ _ _) = r

stackCompiler :: Stack -> Maybe String
stackCompiler (Stack _ c _ _ _) = c

snapshotResolver :: StackSnapshot -> String
snapshotResolver (Snapshot r _ _ _ _ _) = r

-- The package-index entries of a dependency list, as @name-version@.
pkgIndexIds :: [Dependency] -> [String]
pkgIndexIds ds = [ prettyShow i | PkgIndex i _ <- ds ]

-- A trimmed copy of commercialhaskell/stackage-snapshots nightly/2021/8/5.yaml
-- (the snapshot from #1677): the same top-level layout, three of its packages.
stackageSnapshot :: String
stackageSnapshot = unlines
  [ "flags:"
  , "  NineP:"
  , "    bytestring-in-base: false"
  , "publish-time: 2021-08-05T00:22:53.229123808Z"
  , "packages:"
  , "- hackage: AC-Angle-1.0@sha256:e1ffee97819283b714598b947de323254e368f6ae7d4db1d3618fa933f80f065,544"
  , "  pantry-tree:"
  , "    size: 210"
  , "    sha256: 7edd1f1a6228af27c0f0ae53e73468c1d7ac26166f2cb386962db7ff021a2714"
  , "- hackage: ALUT-2.4.0.3@sha256:ab8c2af4c13bc04c7f0f71433ca396664a4c01873f68180983718c8286d8ee05,4118"
  , "  pantry-tree:"
  , "    size: 1562"
  , "    sha256: c9968ebed74fd3956ec7fb67d68e23266b52f55b2d53745defeae20fbcba5579"
  , "- hackage: NineP-0.0.2.1@sha256:3dee595941a0ac87ad7354993cc20c271238bd51570e097c457efb053ee98279,1333"
  , "  pantry-tree:"
  , "    size: 208"
  , "    sha256: f21b2a8d1fe11a1b57fa31671a65c5de576342d3fc94a02f80754410d85fc461"
  , "hidden:"
  , "  prompt: true"
  , "resolver:"
  , "  compiler: ghc-9.0.1"
  ]

-- Run an action with a scratch directory holding the given files.
withFiles :: [(FilePath, String)] -> (FilePath -> IO a) -> IO a
withFiles files act = do
  tmp <- getTemporaryDirectory
  let dir = tmp </> "nix-tools-stack-resolver-tests"
  bracket_ (createDirectoryIfMissing True dir) (removeDirectoryRecursive dir) $ do
    mapM_ (\(name, contents) -> writeFile (dir </> name) contents) files
    act dir

-- Decode @stack.yaml@ in the directory and resolve its snapshot, as stack-to-nix does.
resolveIn :: FilePath -> IO Stack
resolveIn dir = do
  let stackYaml = dir </> "stack.yaml"
  r <- Y.decodeFileEither stackYaml
  case r of
    Left e  -> assertFailure ("unexpected parse failure: " ++ show e) >> undefined
    Right s -> resolveSnapshot stackYaml s

main :: IO ()
main = defaultMain $ testGroup "stack resolver parsing"
  [ testCase "stack.yaml resolver as a plain string" $ do
      s <- decode "resolver: lts-20.11\n"
      stackResolver s @?= "lts-20.11"
      stackCompiler s @?= Nothing

  , testCase "stack.yaml snapshot synonym" $ do
      s <- decode "snapshot: lts-21.0\npackages: []\n"
      stackResolver s @?= "lts-21.0"

  , testCase "stack.yaml resolver in pantry object form uses url (#1677)" $ do
      s <- decode "resolver:\n  url: https://example.com/snap.yaml\n  sha256: deadbeef\n  size: 42\n"
      stackResolver s @?= "https://example.com/snap.yaml"

  , testCase "stack.yaml resolver as a { filepath } object" $ do
      s <- decode "resolver:\n  filepath: snapshots/my.yaml\n"
      stackResolver s @?= "snapshots/my.yaml"

  , testCase "compiler-only resolver also sets the compiler" $ do
      s <- decode "resolver:\n  compiler: ghc-9.0.1\n"
      stackResolver s @?= "ghc-9.0.1"
      stackCompiler s @?= Just "ghc-9.0.1"
      p <- decode "resolver: ghc-9.2.8\n"
      stackCompiler p @?= Just "ghc-9.2.8"

  , testCase "an explicit compiler wins over the resolver's" $ do
      s <- decode "resolver: ghc-9.0.1\ncompiler: ghc-9.0.2\n"
      stackCompiler s @?= Just "ghc-9.0.2"

  , testCase "custom snapshot resolver as a plain string" $ do
      s <- decode "name: my-snap\nresolver: lts-20.11\npackages: []\n"
      snapshotResolver s @?= "lts-20.11"

  , testCase "custom snapshot resolver in pantry object form (#1677)" $ do
      s <- decode "name: my-snap\nresolver:\n  url: https://example.com/snap.yaml\n  sha256: deadbeef\n  size: 42\npackages: []\n"
      snapshotResolver s @?= "https://example.com/snap.yaml"

  , testCase "an unknown resolver object is rejected, naming the field" $
      case Y.decodeEither' (B8.pack "resolver:\n  sha256: deadbeef\n") :: Either Y.ParseException Stack of
        Left e  -> assertBool ("error should mention resolver: " ++ show e)
                     ("resolver" `isInfixOf` show e)
        Right s -> assertFailure ("expected failure, got resolver " ++ show (stackResolver s))

  , testCase "stackage-snapshots file: compiler resolver, hackage objects, flags (#1677)" $ do
      Snapshot r c _ pkgs flags _ <- decode stackageSnapshot
      r @?= "ghc-9.0.1"
      c @?= Just "ghc-9.0.1"
      pkgIndexIds pkgs @?= ["AC-Angle-1.0", "ALUT-2.4.0.3", "NineP-0.0.2.1"]
      HM.lookup "NineP" flags @?= Just (HM.fromList [("bytestring-in-base", False)])

  , testCase "stack.yaml pointing at a local stackage-snapshots file resolves end to end" $
      withFiles [ ("stack.yaml", "resolver: snap.yaml\nextra-deps:\n- foo-1.0\n")
                , ("snap.yaml", stackageSnapshot) ] $ \dir -> do
        Stack r c pkgs _ _ <- resolveIn dir
        r @?= "ghc-9.0.1"
        c @?= Just "ghc-9.0.1"
        pkgIndexIds pkgs @?= ["foo-1.0", "AC-Angle-1.0", "ALUT-2.4.0.3", "NineP-0.0.2.1"]

  , testCase "a { filepath } resolver resolves relative to stack.yaml" $
      withFiles [ ("stack.yaml", "resolver:\n  filepath: snap.yaml\n")
                , ("snap.yaml", stackageSnapshot) ] $ \dir -> do
        Stack r _ pkgs _ _ <- resolveIn dir
        r @?= "ghc-9.0.1"
        length (pkgIndexIds pkgs) @?= 3
  ]
