module SliceSharing (newCounter) where

import Control.Monad.Primitive (RealWorld)
import Data.Primitive.MutVar (MutVar, newMutVar)

newCounter :: IO (MutVar RealWorld Int)
newCounter = newMutVar 0
