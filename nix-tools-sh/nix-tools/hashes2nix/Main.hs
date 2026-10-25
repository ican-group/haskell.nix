{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import System.Environment (getArgs)
import System.Directory
import System.FilePath
import Control.Monad

import Nix.Pretty (prettyNix)
import Nix.Expr

import Data.Aeson
import Lens.Micro
import Lens.Micro.Aeson

import Data.String (fromString)

import Cabal2Nix.Util

main :: IO ()
main = getArgs >>= \case
  [path] -> do
    print . prettyNix =<< hashes path
  _ -> putStrLn "call with /path/to/all-cabal-hashes (Hashes2Nix /path/to/all-cabal-hashes)"

hash :: FilePath -> String -> String -> IO (Binding NExpr)
hash p pkg version = do
  let json = p </> pkg </> version </> pkg <.> "json"
      version' = fromString . quoted $ version
  doesFileExist json >>= \case
    True -> decodeValue json >>= \case
      Just obj -> case obj ^? key "package-hashes" . key "SHA256" . _String of
        Just hash -> pure $ version' $= mkStr hash
        Nothing   -> pure $ version' $= mkNull
      Nothing     -> pure $ version' $= mkNull
    False         -> pure $ version' $= mkNull
  where decodeValue :: FilePath -> IO (Maybe Value)
        decodeValue = decodeFileStrict'

hashes :: FilePath -> IO NExpr
hashes p =
  do pkgs <- listDirectories p
     fmap mkNonRecSet . forM pkgs $ \pkg ->
       do versions <- listDirectories (p </> pkg)
          let pkg' = fromString . quoted $ pkg
          fmap (bindTo pkg' . mkNonRecSet) . forM versions $ \version ->
            hash p pkg version

