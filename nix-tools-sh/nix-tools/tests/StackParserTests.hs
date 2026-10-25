{-# LANGUAGE OverloadedStrings #-}

-- | Pure parser tests for the stack.yaml / custom-snapshot decoders in
-- "Stack2nix.Stack".  These need no external programs or network, unlike the
-- golden tests in "Tests.hs".
module Main (main) where

import Data.ByteString (ByteString)
import qualified Data.Yaml as Yaml
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Stack2nix.Stack (StackSnapshot (..))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Stack2nix.Stack parser"
    [ testCase "custom snapshot without a name parses (#1678)" $
        -- stack does not require `name:` in a custom snapshot, and
        -- stack-to-nix discards it, so a name-less snapshot must parse.
        snapshotName "resolver: lts-18.0\n" @?== "custom-snapshot"
    , testCase "custom snapshot keeps an explicit name" $
        snapshotName "resolver: lts-18.0\nname: my-snapshot\n" @?== "my-snapshot"
    ]
  where
    -- Decode a snapshot document and project out its (defaulted) name.
    snapshotName :: ByteString -> IO String
    snapshotName doc =
      case Yaml.decodeEither' doc of
        Left err -> assertFailure ("failed to parse snapshot: " ++ show err)
        Right (Snapshot _ _ name _ _ _) -> pure name

    -- Run the IO action and compare its result.
    (@?==) :: (Eq a, Show a) => IO a -> a -> IO ()
    action @?== expected = action >>= (@?= expected)
