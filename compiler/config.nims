# Configuration for Hybrid Memory-Safe Nim Compiler (bin/nim_safe.exe)

import std/os

switch("hint", "XDeclaredButNotUsed:off")

switch("define", "booting")
switch("define", "nimcore")
switch("define", "leanCompiler")
switch("define", "nimPreviewSlimSystem")
switch("define", "nimPreviewCstringConversion")
switch("define", "nimPreviewRangeDefault")
switch("define", "nimPreviewNonVarDestructor")
switch("define", "nimPreviewCheckedClose")
switch("define", "nimPreviewAsmSemSymbol")
switch("define", "nimPreviewCStringComparisons")
switch("define", "nimPreviewDuplicateModuleError")
switch("define", "useStdoutAsStdmsg")

switch("threads", "off")

var nimRoot = getEnv("NIM_ROOT")
if nimRoot.len == 0:
  nimRoot = getCurrentCompilerExe().parentDir.parentDir

switch("path", ".")
switch("path", nimRoot / "compiler")
switch("path", nimRoot / "dist" / "checksums" / "src")
switch("path", nimRoot)
switch("cincludes", nimRoot / "lib" / "wrappers" / "libffi" / "common")
