-- | The git-fetch cache shared by @plan-to-nix@ and @stack-to-nix@.
--
-- This used to be two copies (@Plan2Nix.Cache@ and @Stack2nix.Cache@) that
-- drifted apart: the Plan2Nix copy stored a @NOHASH@ placeholder for empty
-- hashes so that the whitespace-delimited format still round-trips through
-- 'words', while the Stack2nix copy wrote a raw empty string (corrupting the
-- cache-file format for local packages), and only the Stack2nix copy forced
-- the reads/writes strictly.  This module keeps the union of the correct
-- behaviours: the @NOHASH@ placeholder *and* the strict IO.
module NixTools.Cache
  ( readCache
  , appendCache
  , cacheHits
  ) where

import Control.DeepSeq ((<$!!>))
import Control.Exception (catch, SomeException(..))
import Data.Either (partitionEithers)
import Data.List (isPrefixOf)

readCache :: FilePath
          -> IO ( [[String]] -- malformed (nonblank) lines, as words
                , [( String -- url
                   , String -- rev
                   , String -- subdir
                   , String -- sha256
                   , String -- pkgname
                   , String -- nixexpr-path
                   )] )
readCache f = partitionEithers . map toTuple . filter (not . null) . map words . lines <$!!> readFile f
  where
    -- The cache is advisory, so set aside any line we cannot make sense of (a
    -- truncated one from an interrupted `appendCache`) instead of letting an
    -- incomplete pattern match abort the whole read and throw away every other
    -- entry.  `cacheHits` treats a key such a line might belong to as a miss.
    toTuple [ url, rev, subdir, sha256, pkgname, exprPath ]
      = Right ( url, rev, subdir, if sha256 == "NOHASH" then "" else sha256, pkgname, exprPath )
    toTuple ws = Left ws

-- When we do not need a hash (when the files are local) we store "NOHASH" instead of ""
-- in the file so that the use of `words` function in `readCache` still works.
appendCache :: FilePath -> String -> String -> String -> String -> String -> String -> IO ()
appendCache f url rev subdir sha256 pkgname exprPath = do
  appendFile f $! unwords [ url, rev, subdir, if null sha256 then "NOHASH" else sha256, pkgname, exprPath ] ++ "\n"

cacheHits :: FilePath -> String -> String -> String -> IO [ (String, String) ]
cacheHits f url rev subdir
  = do (malformed, cache) <- catch' (readCache f) (const (pure ([], [])))
       -- One (url, rev, subdir) can map to several packages, so a damaged row
       -- for this key would otherwise leave a nonempty but incomplete hit list
       -- and the missing package would be silently dropped.  Report a full miss
       -- instead (we just fetch again).  A truncated row's words are prefixes
       -- of the key's, the last possibly cut short.
       return $ if any (\ws -> and (zipWith isPrefixOf ws [url, rev, subdir])) malformed
         then []
         else [ ( pkgname, exprPath )
              | ( url', rev', subdir', _sha256, pkgname, exprPath ) <- cache
              , url == url'
              , rev == rev'
              , subdir == subdir' ]
  where catch' :: IO a -> (SomeException -> IO a) -> IO a
        catch' = catch
