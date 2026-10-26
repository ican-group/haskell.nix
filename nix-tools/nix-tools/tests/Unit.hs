module Main (main) where

import Data.Maybe (mapMaybe)

import Distribution.Pretty (prettyShow)
import Distribution.Types.PackageId (PackageIdentifier (..))
import Distribution.Types.PackageName (PackageName)

import Stack2nix.External.Resolve (dependencyPackageName, mergeDependencies)
import Stack2nix.Stack (Dependency (..), parsePackageIdentifier)

import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase, (@?=))

-- | Build a package-index dependency (an @extra-deps@ / snapshot @packages@
-- entry) from a @name-version@ string.
pkgIndex :: String -> Dependency
pkgIndex s = case parsePackageIdentifier s of
  Just (pkgId, rev) -> PkgIndex pkgId rev
  Nothing           -> error ("pkgIndex: could not parse " ++ show s)

-- | Look up the version emitted for a given package name in a merged
-- dependency list.
lookupVersion :: PackageName -> [Dependency] -> [String]
lookupVersion name deps =
  [ prettyShow (pkgVersion pkgId)
  | PkgIndex pkgId _ <- deps
  , pkgName pkgId == name
  ]

names :: [Dependency] -> [PackageName]
names = mapMaybe dependencyPackageName

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Stack2nix.External.Resolve.mergeDependencies"
  [ testCase "extra-dep shadows overlapping snapshot package (issue #1690)" $ do
      -- stack.yaml extra-deps take precedence over snapshot packages.
      let stackDeps = [pkgIndex "foo-2.0"]
          snapshot  = [pkgIndex "foo-1.0"]
          merged    = mergeDependencies stackDeps snapshot
      assertEqual "only one definition for foo" 1 (length (names merged))
      assertEqual "foo resolves to the extra-dep version"
        ["2.0"] (lookupVersion (packageName "foo") merged)

  , testCase "non-overlapping deps are all kept, in order" $ do
      let stackDeps = [pkgIndex "foo-2.0"]
          snapshot  = [pkgIndex "bar-1.0"]
          merged    = mergeDependencies stackDeps snapshot
      map prettyName (names merged) @?= ["foo", "bar"]

  , testCase "no overlap is identical to plain concatenation" $ do
      let stackDeps = [pkgIndex "foo-2.0", pkgIndex "baz-3.1"]
          snapshot  = [pkgIndex "bar-1.0"]
      map prettyName (names (mergeDependencies stackDeps snapshot))
        @?= map prettyName (names (stackDeps <> snapshot))

  , testCase "only the lower-priority overlap is dropped" $ do
      let stackDeps = [pkgIndex "foo-2.0"]
          snapshot  = [pkgIndex "foo-1.0", pkgIndex "bar-1.0"]
          merged    = mergeDependencies stackDeps snapshot
      map prettyName (names merged) @?= ["foo", "bar"]
      assertEqual "foo resolves to the extra-dep version"
        ["2.0"] (lookupVersion (packageName "foo") merged)

  , testCase "un-keyable deps (local paths) are always kept" $ do
      let stackDeps = [pkgIndex "foo-2.0", LocalPath "."]
          snapshot  = [pkgIndex "foo-1.0", LocalPath "vendor/foo"]
          merged    = mergeDependencies stackDeps snapshot
          isLocal (LocalPath _) = True
          isLocal _             = False
      assertEqual "both local paths retained" 2 (length (filter isLocal merged))
      assertEqual "foo resolves to the extra-dep version"
        ["2.0"] (lookupVersion (packageName "foo") merged)
  ]

-- | Parse a bare package name (via a throwaway version).
packageName :: String -> PackageName
packageName n = case parsePackageIdentifier (n ++ "-0") of
  Just (pkgId, _) -> pkgName pkgId
  Nothing         -> error ("packageName: could not parse " ++ show n)

prettyName :: PackageName -> String
prettyName = prettyShow
