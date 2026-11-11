## apps/wiztree/wiztree.nim — WizTree High-Performance Disk Scanner Standalone Executable
##
## Primary application entry point for the WizTree engine.
##
## Features:
## - Direct NTFS MFT streaming via FSCTL_ENUM_USN_DATA (with transparent Win32 fallback)
## - O(1) filename arena interning and compact 40-byte POD cache-friendly nodes
## - Sub-millisecond top items sorting via algx/ultrasort
## - Zero-DOM streaming JSON export via algx/zeropack
## - Formatted table, CSV, and streaming JSON export options
##
## Compiles directly under --mm:orc --threads:on --panics:on.

import std/os
import ./cli

export cli

when isMainModule:
  let code = runCli(commandLineParams())
  quit(code)
