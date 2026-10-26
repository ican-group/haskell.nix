{-# LANGUAGE OverloadedStrings #-}

-- | Self-contained parser tests for #1676: a package's @ghc-options@ must
-- parse whether it is written as a single string (as in @stack.yaml@) or as
-- an array of strings (as in snapshot/resolver definitions).  These tests are
-- pure (no external tools or network), unlike the golden @tests@ suite.
module Main (main) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import Data.Yaml (decodeEither')

import Stack2nix.Stack (Stack(..), StackSnapshot(..), GhcOptionsValue(..))

import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, assertEqual, assertFailure)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "ghc-options parsing (#1676)"
  [ testCase "stack.yaml scalar-string ghc-options" $ do
      let yaml = BS.unlines
            [ "resolver: lts-20.0"
            , "ghc-options:"
            , "  mypkg: -O2 -Wall"
            ]
      case decodeEither' yaml of
        Left err -> assertFailure ("failed to parse Stack: " ++ show err)
        Right (Stack _ _ _ _ ghcOpts) ->
          assertEqual "options" (Just ["-O2 -Wall"]) (lookupOptions "mypkg" ghcOpts)

  , testCase "stack.yaml quoted argument keeps its whitespace" $ do
      let yaml = BS.unlines
            [ "resolver: lts-20.0"
            , "ghc-options:"
            , "  mypkg: '-O2 -i\"dir  with  spaces\"'"
            ]
      case decodeEither' yaml of
        Left err -> assertFailure ("failed to parse Stack: " ++ show err)
        Right (Stack _ _ _ _ ghcOpts) ->
          assertEqual "options" (Just ["-O2 -i\"dir  with  spaces\""])
            (lookupOptions "mypkg" ghcOpts)

  , testCase "snapshot array ghc-options" $ do
      let yaml = BS.unlines
            [ "resolver: lts-20.0"
            , "name: my-snapshot"
            , "ghc-options:"
            , "  mypkg:"
            , "    - -O2"
            , "    - -Wall"
            ]
      case decodeEither' yaml of
        Left err -> assertFailure ("failed to parse StackSnapshot: " ++ show err)
        Right (Snapshot _ _ _ _ _ ghcOpts) ->
          assertEqual "options" (Just ["-O2", "-Wall"]) (lookupOptions "mypkg" ghcOpts)

  , testCase "snapshot array entry keeps its whitespace" $ do
      let yaml = BS.unlines
            [ "resolver: lts-20.0"
            , "name: my-snapshot"
            , "ghc-options:"
            , "  mypkg:"
            , "    - -O2"
            , "    - '-i\"dir  with  spaces\"'"
            ]
      case decodeEither' yaml of
        Left err -> assertFailure ("failed to parse StackSnapshot: " ++ show err)
        Right (Snapshot _ _ _ _ _ ghcOpts) ->
          assertEqual "options" (Just ["-O2", "-i\"dir  with  spaces\""])
            (lookupOptions "mypkg" ghcOpts)

  , testCase "snapshot scalar-string ghc-options still parses" $ do
      let yaml = BS.unlines
            [ "resolver: lts-20.0"
            , "name: my-snapshot"
            , "ghc-options:"
            , "  mypkg: -O2 -Wall"
            ]
      case decodeEither' yaml of
        Left err -> assertFailure ("failed to parse StackSnapshot: " ++ show err)
        Right (Snapshot _ _ _ _ _ ghcOpts) ->
          assertEqual "options" (Just ["-O2 -Wall"]) (lookupOptions "mypkg" ghcOpts)
  ]
  where
    lookupOptions :: T.Text -> HM.HashMap T.Text GhcOptionsValue -> Maybe [T.Text]
    lookupOptions k = fmap ghcOptionsList . HM.lookup k
