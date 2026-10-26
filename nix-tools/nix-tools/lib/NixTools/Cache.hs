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
import Data.Either (rights)
import Data.List (isPrefixOf)

type CacheEntry
  = ( String -- url
    , String -- rev
    , String -- subdir
    , String -- sha256
    , String -- pkgname
    , String -- nixexpr-path
    )

-- | The well-formed entries of the cache file, in file order.
readCache :: FilePath -> IO [CacheEntry]
readCache f = rights <$> readCacheLines f

-- | Every nonblank line of the cache file, in file order.  The cache is
-- advisory, so a line we cannot make sense of (a truncated one from an
-- interrupted `appendCache`) is set aside as its words instead of letting an
-- incomplete pattern match abort the whole read and throw away every other
-- entry.
readCacheLines :: FilePath -> IO [Either [String] CacheEntry]
readCacheLines f = map toEntry . filter (not . null) . map words . lines <$!!> readFile f
  where
    toEntry [ url, rev, subdir, sha256, pkgname, exprPath ]
      = Right ( url, rev, subdir, if sha256 == "NOHASH" then "" else sha256, pkgname, exprPath )
    toEntry ws = Left ws

-- When we do not need a hash (when the files are local) we store "NOHASH" instead of ""
-- in the file so that the use of `words` function in `readCache` still works.
appendCache :: FilePath -> String -> String -> String -> String -> String -> String -> IO ()
appendCache f url rev subdir sha256 pkgname exprPath = do
  appendFile f $! unwords [ url, rev, subdir, if null sha256 then "NOHASH" else sha256, pkgname, exprPath ] ++ "\n"

cacheHits :: FilePath -> String -> String -> String -> IO [ (String, String) ]
cacheHits f url rev subdir
  = do entries <- catch' (readCacheLines f) (const (pure []))
       -- One (url, rev, subdir) can map to several packages, so a damaged row
       -- for this key would otherwise leave a nonempty but incomplete hit list
       -- and the missing package would be silently dropped.  Only trust the
       -- rows written after the last damaged row that may belong to this key:
       -- a miss makes the caller fetch again and append the key's complete set
       -- of rows, which then supersede the damaged one.
       return [ ( pkgname, exprPath )
              | Right ( url', rev', subdir', _sha256, pkgname, exprPath ) <- afterLastDamaged entries
              , url == url'
              , rev == rev'
              , subdir == subdir' ]
  where catch' :: IO a -> (SomeException -> IO a) -> IO a
        catch' = catch
        afterLastDamaged = reverse . takeWhile (not . damagedForKey) . reverse
        -- A truncated row keeps the leading words of the row it was cut from,
        -- and only the last of them can be cut short.
        damagedForKey (Left ws) =
          let n = length ws
          in and (zipWith3 (\i w k -> if i == n - 1 then w `isPrefixOf` k else w == k)
                           [0 :: Int ..] ws [url, rev, subdir])
        damagedForKey (Right _) = False
