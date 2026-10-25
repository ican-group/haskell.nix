module Main where

import StackRepos (doStackRepos)
import StackRepos.CLI (parseStackReposArgs)

main :: IO ()
main = parseStackReposArgs >>= doStackRepos
