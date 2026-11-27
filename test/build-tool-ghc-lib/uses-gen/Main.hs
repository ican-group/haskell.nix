module Main (main) where

import UsesGen (ghcLibVersion)

main :: IO ()
main = putStrLn ("built with a tool that links ghc " ++ ghcLibVersion)
