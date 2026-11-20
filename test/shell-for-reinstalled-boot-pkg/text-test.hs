import qualified Data.Text as T

main :: IO ()
main = putStrLn (T.unpack (T.toUpper (T.pack "ok")))
