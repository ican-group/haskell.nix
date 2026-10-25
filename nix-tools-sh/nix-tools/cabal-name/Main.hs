module Main where

import CabalName (doCabalName)
import CabalName.CLI (parseCabalNameArgs)

main :: IO ()
main = parseCabalNameArgs >>= doCabalName
