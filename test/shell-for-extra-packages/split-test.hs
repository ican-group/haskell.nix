import Data.List.Split (splitOn)

main :: IO ()
main = print (splitOn "," "a,b,c")
