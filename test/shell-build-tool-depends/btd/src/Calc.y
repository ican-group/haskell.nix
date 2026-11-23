{
module Calc (parseCalc) where
}

%name parseCalc
%tokentype { Char }
%error { parseError }

%token
  'x' { 'x' }

%%

Exp : 'x' { () }

{
parseError :: [Char] -> a
parseError _ = error "parse error"
}
