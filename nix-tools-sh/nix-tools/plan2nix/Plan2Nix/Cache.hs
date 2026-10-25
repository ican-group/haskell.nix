-- Note: this is identical to Stack2nix.Cache
module Plan2Nix.Cache
  ( readCache
  , appendCache
  , cacheHits
  ) where

import Control.Exception (catch, SomeException(..))

readCache :: FilePath
          -> IO [( String -- url
                 , String -- rev
                 , String -- subdir
                 , String -- sha256
                 , String -- pkgname
                 , String -- nixexpr-path
                 )]
readCache f = fmap (toTuple . words) . lines <$> readFile f
  where toTuple [ url, rev, subdir, sha256, pkgname, exprPath ]
          = ( url, rev, subdir, if sha256 == "NOHASH" then "" else sha256, pkgname, exprPath )

-- When we do not need a hash (when the files are local) we store "NOHASH" instead of ""
-- in the file so that the use of `words` function in `readCache` still works.
appendCache :: FilePath -> String -> String -> String -> String -> String -> String -> IO ()
appendCache f url rev subdir sha256 pkgname exprPath = do
  appendFile f $ unwords [ url, rev, subdir, if null sha256 then "NOHASH" else sha256, pkgname, exprPath ]
  appendFile f "\n"

cacheHits :: FilePath -> String -> String -> String -> IO [ (String, String) ]
cacheHits f url rev subdir
  = do cache <- catch' (readCache f) (const (pure []))
       return [ ( pkgname, exprPath )
              | ( url', rev', subdir', sha256, pkgname, exprPath ) <- cache
              , url == url'
              , rev == rev'
              , subdir == subdir' ]
  where catch' :: IO a -> (SomeException -> IO a) -> IO a
        catch' = catch
