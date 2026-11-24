module Lib where

import Acme.Box ()
import Acme.Dont (don't)
import Acme.Missiles (launchMissiles)

safe :: IO ()
safe = don't launchMissiles
