{-# LANGUAGE CPP #-}
module Lib
    ( someFunc
    ) where

-- The stack build (stack.yaml) also passes the ghc-options given for the
-- special stack keys $locals, $targets and $everything (see issue 827).
#if defined(STACK_BUILD) && !(defined(STACK_LOCALS) && defined(STACK_TARGETS) && defined(STACK_EVERYTHING))
#error "ghc-options for $locals, $targets or $everything from stack.yaml were not applied"
#endif

#ifdef TEST_GHC_OPTION
someFunc :: IO ()
someFunc = putStrLn "someFunc"
#endif
