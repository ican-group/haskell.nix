module Stack2nix.External.Resolve
  ( resolveSnapshot
  ) where

import Control.Monad (unless)
import Data.Aeson
import Data.Yaml hiding (Parser)
import Control.Applicative ((<|>))
import Data.List (isPrefixOf, isSuffixOf)
import System.FilePath ((</>), dropFileName)

import qualified Data.ByteString.Lazy.Char8 as L8

import Network.HTTP.Client
import Network.HTTP.Client.TLS
import           Network.HTTP.Types.Status  (ok200)
import Control.Exception.Base (SomeException(..),PatternMatchFail(..))

import Stack2nix.Stack (Stack(..), StackSnapshot(..))

-- | A @resolver@ value in a stack.yaml file may point to an URL. As such
-- we need to be able to fetch one.
decodeURLEither :: FromJSON a => String -> IO (Either ParseException a)
decodeURLEither url
  | not (("http://" `isPrefixOf` url) || ("https://" `isPrefixOf` url))
  = return . Left . OtherParseException . SomeException . PatternMatchFail $ "No http or https prefix"
  | otherwise = do
      manager <- newManager tlsManagerSettings
      request <- parseRequest url
      response <- httpLbs request manager
      unless (ok200 == responseStatus response) $ error ("failed to download " ++ url)
      return . decodeEither' . L8.toStrict $ responseBody response


-- | If a stack.yaml file contains a @resolver@ that points to
-- a file, resolve that file and merge the snapshot into the
-- @Stack@ record.
resolveSnapshot :: FilePath -> Stack -> IO Stack
resolveSnapshot stackYaml stack@(Stack resolver compiler pkgs flags ghcOptions)
  = if ".yaml" `isSuffixOf` resolver
    then do evalue <- if ("http://" `isPrefixOf` resolver) || ("https://" `isPrefixOf` resolver)
                      then decodeURLEither resolver
                      else decodeFileEither (srcDir </> resolver)
            case evalue of
              Left e -> error (show e)
              Right (Snapshot resolver' compiler' _name pkgs' flags' ghcOptions') ->
                pure $ Stack resolver' (compiler' <|> compiler)  (pkgs <> pkgs') (flags <> flags')
                    (ghcOptions <> ghcOptions')
    else pure stack
  where
    srcDir = dropFileName stackYaml
