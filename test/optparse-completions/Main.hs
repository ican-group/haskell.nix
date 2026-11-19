module Main where

import Options.Applicative

main :: IO ()
main = do
  name <- execParser $ info (helper <*> argument str (metavar "NAME"))
    (fullDesc <> progDesc "Greet NAME")
  putStrLn ("Hello, " ++ name)
