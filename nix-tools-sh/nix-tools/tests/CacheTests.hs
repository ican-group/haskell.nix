-- | Tests for the git-fetch cache file shared by plan-to-nix and stack-to-nix.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM_, when)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.HUnit

import NixTools.Cache

url, rev :: String
url = "https://github.com/foo/bar"
rev = "0123456789abcdef"

-- | Run with the path of a cache file holding the given contents.
withCache :: String -> (FilePath -> IO a) -> IO a
withCache contents act = do
  tmp <- getTemporaryDirectory
  bracket (openTempFile tmp "nix-tools-cache")
          (\(f, _) -> removeFile f)
          (\(f, h) -> hClose h >> writeFile f contents >> act f)

-- | What the call sites do: on a miss, fetch and append every package of the key.
fetchIfMissed :: FilePath -> String -> [(String, String)] -> IO ()
fetchIfMissed f subdir pkgs = do
  hits <- cacheHits f url rev subdir
  when (null hits) $ forM_ pkgs $ \(pkg, nix) -> appendCache f url rev subdir "sha" pkg nix

main :: IO ()
main = defaultMain $ testGroup "NixTools.Cache"
  [ testCase "round trip, including an empty (local) hash" $ withCache "" $ \f -> do
      appendCache f url rev "." "" "bar" "bar.nix"
      appendCache f url rev "sub" "sha" "baz" "baz.nix"
      entries <- readCache f
      entries @?= [ (url, rev, ".", "", "bar", "bar.nix")
                  , (url, rev, "sub", "sha", "baz", "baz.nix") ]
      (@?= [("bar", "bar.nix")]) =<< cacheHits f url rev "."
      (@?= [("baz", "baz.nix")]) =<< cacheHits f url rev "sub"

  , testCase "a legacy 5-column row is a miss, and heals after one fetch" $
      withCache (unwords [url, rev, ".", "bar", "bar.nix"] ++ "\n") $ \f -> do
        (@?= []) =<< cacheHits f url rev "."
        forM_ [1 .. 3 :: Int] $ \_ -> fetchIfMissed f "." [("bar", "bar.nix")]
        (@?= [("bar", "bar.nix")]) =<< cacheHits f url rev "."
        (@?= 2) . length . lines =<< readFile f

  , testCase "a truncated row for a multi-package key is a miss until refetched" $
      withCache (unlines [ unwords [url, rev, ".", "sha", "a", "a.nix"]
                         , unwords [url, rev, ".", "sha", "b"] ]) $ \f -> do
        (@?= []) =<< cacheHits f url rev "."
        fetchIfMissed f "." [("a", "a.nix"), ("b", "b.nix")]
        (@?= [("a", "a.nix"), ("b", "b.nix")]) =<< cacheHits f url rev "."

  , testCase "a truncated row only affects keys it could belong to" $
      withCache (unlines [ unwords [url ++ "-fork", rev, ".", "sha", "f", "f.nix"]
                         , unwords [url, "fedcba", ".", "sha", "g", "g.nix"]
                         , unwords [url, take 4 rev] ]) $ \f -> do
        (@?= [("f", "f.nix")]) =<< cacheHits f (url ++ "-fork") rev "."
        (@?= [("g", "g.nix")]) =<< cacheHits f url "fedcba" "."
        (@?= []) =<< cacheHits f url rev "."

  , testCase "a missing cache file is a miss" $ do
      f <- withCache "" pure
      (@?= []) =<< cacheHits f url rev "."
  ]
