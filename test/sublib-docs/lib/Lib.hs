-- | Lib with haddocks
module Lib where

import Slib (Greeting(..))

-- | world string
world :: String
world = "world"

-- | Uses a type from the @slib@ sublibrary so the haddocks link to
-- that component's documentation.
greeting :: Greeting
greeting = Greeting world
