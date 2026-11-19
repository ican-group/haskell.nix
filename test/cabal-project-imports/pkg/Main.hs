{-# LANGUAGE CPP #-}
module Main (main) where

main :: IO ()
#ifdef FROM_IMPORT
main = putStrLn "from-import"
#else
main = putStrLn "missing"
#endif
