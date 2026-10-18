{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell #-}
module Lib where

#ifdef TEST_I386_ELF_GOT_RELOCS
import Control.Monad (unless)
import Foreign.C.Types (CInt (..))
import Language.Haskell.TH.Syntax (lift, runIO)
import RelocProbe (readA, readB)

relocationProbe :: Int
relocationProbe = $(do
  (CInt a, CInt b) <- runIO ((,) <$> readA <*> readB)
  unless (a == 7 && b == 29) (fail "i386 PIC GOT relocation probe returned incorrect values")
  lift (fromIntegral a + fromIntegral b :: Int))
#endif

{-# ANN module "HLint: ignore Use fmap" #-}

x=1
