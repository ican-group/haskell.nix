module Main where
import Plan2Nix (doPlan2Nix)
import Plan2Nix.CLI (parsePlan2NixArgs)

main :: IO ()
main = parsePlan2NixArgs >>= doPlan2Nix
