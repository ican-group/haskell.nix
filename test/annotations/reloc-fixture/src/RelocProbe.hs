{-# LANGUAGE ForeignFunctionInterface #-}
module RelocProbe (readA, readB) where

import Foreign.C.Types (CInt (..))

foreign import ccall unsafe "rel10_read_a" readA :: IO CInt
foreign import ccall unsafe "rel10_read_b" readB :: IO CInt
