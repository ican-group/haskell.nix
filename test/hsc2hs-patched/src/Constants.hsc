-- Constants whose values are the same on every target, so the test can check
-- them without running any C.  The last directive matters most: the
-- unpatched batching hsc2hs read the last constant of every file as 0 on
-- wasm and the JavaScript backend.
module Constants where

#include <stdint.h>

#define HSC2HS_PATCHED_LAST 42

int32Size :: Int
int32Size = #{size int32_t}

minusOne :: Int
minusOne = #{const -1}

-- gcc places a zero value in .bss as `.zero 8`.
zero :: Int
zero = #{const 0}

maxWord64 :: Integer
maxWord64 = #{const UINT64_MAX}

lastOne :: Int
lastOne = #{const HSC2HS_PATCHED_LAST}
