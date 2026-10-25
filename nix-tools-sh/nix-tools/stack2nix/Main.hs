module Main where

import Stack2nix (doStack2nix)
import Stack2nix.CLI (parseStack2nixArgs)

main :: IO ()
main = parseStack2nixArgs >>= doStack2nix
