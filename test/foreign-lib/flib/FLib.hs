{-# LANGUAGE ForeignFunctionInterface #-}
module FLib () where

import Foreign.C.Types (CInt (..))
import Adder (add)

foreign export ccall hsflib_add :: CInt -> CInt -> CInt

hsflib_add :: CInt -> CInt -> CInt
hsflib_add a b = fromIntegral (add (fromIntegral a) (fromIntegral b))
