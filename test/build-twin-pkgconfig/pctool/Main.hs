{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module Main (main) where

import System.Environment (getArgs)
#ifdef HAVE_ZLIB
import Foreign.C.String (CString, peekCString)

foreign import ccall unsafe "zlibVersion" c_zlibVersion :: IO CString

zlibVersion :: IO String
zlibVersion = c_zlibVersion >>= peekCString
#else
zlibVersion :: IO String
zlibVersion = return "none"
#endif

-- GHC calls `pctool <original> <input> <output>`; replace @ZLIB@ in the
-- source with the zlib version this tool was linked against.
main :: IO ()
main = do
  [_orig, input, output] <- getArgs
  v <- zlibVersion
  src <- readFile input
  writeFile output (subst (show v) src)
 where
  subst v ('@':'Z':'L':'I':'B':'@':rest) = v ++ subst v rest
  subst v (c:rest) = c : subst v rest
  subst _ [] = []
