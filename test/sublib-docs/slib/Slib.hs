-- | sublib with haddocks
module Slib where

import Data.Aeson (Value(..))

-- | hello string
hello :: String
hello = "Hello"

-- | A greeting.  Documented here so `Lib`'s haddocks link to this
-- sublibrary's docs.
newtype Greeting = Greeting String

-- | Uses a type from @aeson@ (a non-GHC library) so the haddocks
-- link to that package's documentation (see #2580).
helloValue :: Value
helloValue = String mempty
