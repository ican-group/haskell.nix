module SymlinkPkg (message) where

import Shared (sharedMessage)

message :: String
message = "symlink-pkg: " ++ sharedMessage
