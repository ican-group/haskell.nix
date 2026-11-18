{-# LANGUAGE TemplateHaskell #-}
module Lib (answer) where

import Language.Haskell.TH (integerL, litE)

answer :: Int
answer = $(litE (integerL 42))
