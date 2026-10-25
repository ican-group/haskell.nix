-- I am a sinner!
{-# language RecordWildCards #-}

module Main (main) where

import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Time.Format.ISO8601
import Codec.Archive.Tar as Tar
import Codec.Archive.Tar.Entry as Tar
import Data.ByteString.Lazy as BS hiding (filter)
import Codec.Compression.GZip as GZip

import Options.Applicative hiding (option)
import Options.Applicative

-- | Convert the standard 'UTCTime' type into the 'EpochTime' used by the @tar@ library.
toEpochTime :: UTCTime -> EpochTime
toEpochTime = floor . utcTimeToPOSIXSeconds

-- | Filter Haskell Index
filterHaskellIndex :: FilePath -> UTCTime -> FilePath -> IO ()
filterHaskellIndex orig indexState out =
  BS.writeFile out . nukeHeaderOS . GZip.compress . Tar.write . f . Tar.read . GZip.decompress =<< BS.readFile orig
  where f = filter ((<= ts) . Tar.entryTime) . toList
        ts = toEpochTime indexState
        -- gzip headers containt he OS, but we want a stable hash.
        -- 0xff is unknown OS. http://www.zlib.org/rfc-gzip.html
        nukeHeaderOS :: BS.ByteString -> BS.ByteString
        nukeHeaderOS bs = BS.take 9 bs <> BS.singleton 0xff <> BS.drop 10 bs

-- | Convert @Entries e@ to a list while throwing an error on failure.
toList :: Show e => Entries e -> [Entry]
toList (Next e es) = e:(toList es)
toList Done = []
toList (Fail e) = error (show e)

--------------------------------------------------------------------------------
-- CLI Argument
data Args = Args
  { argOutput :: FilePath
  , argInput  :: FilePath
  , argIndexState :: UTCTime
  } deriving Show

args :: Parser Args
args = Args
  <$> strOption ( long "output" <> short 'o' <> value "00-index.tar.gz" <> showDefault <> metavar "FILE" <> help "The output index" )
  <*> strOption ( long "input" <> short 'i' <> value "01-index.tar.gz" <> showDefault <> metavar "FILE" <> help "The input index" )
  <*> option (maybeReader iso8601ParseM) ( long "indexState" <> short 's' <> metavar "INDEX" <> help "Index State ( YYYY-MM-DDTHH:MM:SSZ )" )

main :: IO ()
main = execParser opts >>= \Args{..} -> filterHaskellIndex argInput argIndexState argOutput
  where opts = info (args <**> helper)
          ( fullDesc
         <> progDesc "Generate a truncated Hackage index"
         <> header "truncate-index - a hackage index truncater" )
