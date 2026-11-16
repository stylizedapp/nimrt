## nimui/clipboard — Native Win32 Clipboard & Headless In-Memory Fallback
##
## Strict invariants:
## - Pure native Win32 clipboard API interop without external C dependencies.
## - Unicode CF_UNICODETEXT format with safe UTF-16 <-> UTF-8 conversion.
## - Safe procedures (getClipboardText, setClipboardText) with {.raises: [].}.
## - In-memory fallback buffer for headless/non-Windows environments.
## - Zero memory leaks under ARC/ORC.

import ../corex/[unicode, result]
export unicode

when defined(windows):
  const
    CF_UNICODETEXT* = 13'u32
    GMEM_MOVEABLE* = 0x0002'u32

  # Safe: standard Win32 user32/kernel32 clipboard and global memory FFI bindings.
  proc OpenClipboard(hWndNewOwner: pointer): int32 {.trustedUnsafe, stdcall, dynlib: "user32", importc: "OpenClipboard", raises: [].}
  proc CloseClipboard(): int32 {.trustedUnsafe, stdcall, dynlib: "user32", importc: "CloseClipboard", raises: [].}
  proc EmptyClipboard(): int32 {.trustedUnsafe, stdcall, dynlib: "user32", importc: "EmptyClipboard", raises: [].}
  proc GetClipboardData(uFormat: uint32): pointer {.trustedUnsafe, stdcall, dynlib: "user32", importc: "GetClipboardData", raises: [].}
  proc SetClipboardData(uFormat: uint32, hMem: pointer): pointer {.trustedUnsafe, stdcall, dynlib: "user32", importc: "SetClipboardData", raises: [].}
  proc IsClipboardFormatAvailable(uFormat: uint32): int32 {.trustedUnsafe, stdcall, dynlib: "user32", importc: "IsClipboardFormatAvailable", raises: [].}

  proc GlobalAlloc(uFlags: uint32, dwBytes: uint): pointer {.trustedUnsafe, stdcall, dynlib: "kernel32", importc: "GlobalAlloc", raises: [].}
  proc GlobalLock(hMem: pointer): pointer {.trustedUnsafe, stdcall, dynlib: "kernel32", importc: "GlobalLock", raises: [].}
  proc GlobalUnlock(hMem: pointer): int32 {.trustedUnsafe, stdcall, dynlib: "kernel32", importc: "GlobalUnlock", raises: [].}
  proc GlobalFree(hMem: pointer): pointer {.trustedUnsafe, stdcall, dynlib: "kernel32", importc: "GlobalFree", raises: [].}
  proc Sleep(dwMilliseconds: uint32) {.trustedUnsafe, stdcall, dynlib: "kernel32", importc: "Sleep", raises: [].}

# =============================================================================
# Context-Scoped & Thread-Local Fallback Buffer (No Unsynchronized Globals)
# =============================================================================

type
  ClipboardContext* = object
    fallbackBuffer*: string
    forceFallback*: bool

var gThreadClipboard {.threadvar.}: ClipboardContext

proc initClipboardContext*(forceFallback: bool = false): ClipboardContext {.raises: [].} =
  ClipboardContext(fallbackBuffer: "", forceFallback: forceFallback)

proc setClipboardForceFallback*(ctx: var ClipboardContext, force: bool) {.raises: [].} =
  ctx.forceFallback = force

proc clearClipboardFallback*(ctx: var ClipboardContext) {.raises: [].} =
  ctx.fallbackBuffer = ""

proc getClipboardFallback*(ctx: ClipboardContext): string {.raises: [].} =
  ctx.fallbackBuffer

proc setClipboardForceFallback*(force: bool) {.raises: [].} =
  ## Force the clipboard system on this thread to use the in-memory fallback buffer (for headless tests).
  gThreadClipboard.forceFallback = force

proc clearClipboardFallback*() {.raises: [].} =
  ## Clears the thread-local in-memory fallback buffer.
  gThreadClipboard.fallbackBuffer = ""

proc getClipboardFallback*(): string {.raises: [].} =
  ## Returns the current text in the thread-local in-memory fallback buffer.
  gThreadClipboard.fallbackBuffer

# =============================================================================
# UTF-16 <-> UTF-8 Safe Conversion
# =============================================================================

proc utf8ToUtf16*(s: string): seq[uint16] {.raises: [].} =
  ## Converts UTF-8 string to a null-terminated seq[uint16] (UTF-16 LE).
  result = newSeqOfCap[uint16](s.len + 1)
  for r in runes(s):
    let cp = uint32(r)
    if cp < 0x10000'u32:
      result.add(uint16(cp))
    else:
      let v = cp - 0x10000'u32
      let highSurrogate = uint16(0xD800'u32 + (v shr 10))
      let lowSurrogate = uint16(0xDC00'u32 + (v and 0x3FF'u32))
      result.add(highSurrogate)
      result.add(lowSurrogate)
  result.add(0'u16)

# Safe: pWide is nil-checked and points to a null-terminated Win32 CF_UNICODETEXT buffer locked via GlobalLock.
proc utf16ToUtf8*(pWide: ptr UncheckedArray[uint16]): string {.trustedUnsafe, raises: [].} =
  ## Converts a null-terminated UTF-16 buffer to a UTF-8 string.
  if pWide == nil:
    return ""
  var i = 0
  while pWide[i] != 0'u16:
    let w1 = pWide[i]
    inc(i)
    if w1 >= 0xD800'u16 and w1 <= 0xDBFF'u16:
      let w2 = pWide[i]
      if w2 >= 0xDC00'u16 and w2 <= 0xDFFF'u16:
        inc(i)
        let cp = 0x10000'u32 + (((uint32(w1) and 0x3FF'u32) shl 10) or (uint32(w2) and 0x3FF'u32))
        result.add(toUTF8(Rune(cp)))
      else:
        result.add(toUTF8(Rune(w1)))
    else:
      result.add(toUTF8(Rune(w1)))

# =============================================================================
# Clipboard Public API
# =============================================================================

when defined(windows):
  proc tryOpenClipboard(retries: int = 5): bool {.raises: [].} =
    for _ in 0 ..< retries:
      if OpenClipboard(nil) != 0:
        return true
      Sleep(2)
    false

proc setClipboardText*(ctx: var ClipboardContext, text: string): bool {.raises: [].} =
  ## Sets the system clipboard text using CF_UNICODETEXT on Windows.
  ## Falls back to the context's in-memory buffer if headless or on non-Windows platforms.
  ctx.fallbackBuffer = text

  if ctx.forceFallback:
    return true

  when defined(windows):
    if not tryOpenClipboard(5):
      return true # Soft-fallback: in-memory buffer is updated

    if EmptyClipboard() == 0:
      discard CloseClipboard()
      return false

    let u16 = utf8ToUtf16(text)
    let bytesCount = uint(u16.len * sizeof(uint16))
    # Safe: Win32 GlobalAlloc/GlobalLock/copyMem/SetClipboardData with nil checks and GlobalFree on failure.
    block trustedUnsafe:
      let hMem = GlobalAlloc(GMEM_MOVEABLE, bytesCount)
      if hMem == nil:
        discard CloseClipboard()
        return false

      let pMem = GlobalLock(hMem)
      if pMem == nil:
        discard GlobalFree(hMem)
        discard CloseClipboard()
        return false

      copyMem(pMem, unsafeAddr u16[0], int(bytesCount))
      discard GlobalUnlock(hMem)

      let hResult = SetClipboardData(CF_UNICODETEXT, hMem)
      if hResult == nil:
        discard GlobalFree(hMem)
        discard CloseClipboard()
        return false

      discard CloseClipboard()
      return true
  else:
    return true

proc setClipboardText*(text: string): bool {.raises: [].} =
  ## Sets the system clipboard text using CF_UNICODETEXT on Windows,
  ## backed by thread-local fallback state when headless or non-Windows.
  setClipboardText(gThreadClipboard, text)

proc getClipboardText*(ctx: var ClipboardContext): string {.raises: [].} =
  ## Retrieves the system clipboard text in UTF-8 format.
  ## Falls back to the context's in-memory buffer if headless, unavailable, or non-Windows.
  if ctx.forceFallback:
    return ctx.fallbackBuffer

  when defined(windows):
    if not tryOpenClipboard(5):
      return ctx.fallbackBuffer

    if IsClipboardFormatAvailable(CF_UNICODETEXT) == 0:
      discard CloseClipboard()
      return ""

    # Safe: Win32 GetClipboardData/GlobalLock/GlobalUnlock with nil checks while clipboard is open.
    var converted = ""
    block trustedUnsafe:
      let hData = GetClipboardData(CF_UNICODETEXT)
      if hData == nil:
        discard CloseClipboard()
        return ""

      let pData = GlobalLock(hData)
      if pData == nil:
        discard CloseClipboard()
        return ""

      converted = utf16ToUtf8(cast[ptr UncheckedArray[uint16]](pData))
      discard GlobalUnlock(hData)
      discard CloseClipboard()

    ctx.fallbackBuffer = converted
    return converted
  else:
    return ctx.fallbackBuffer

proc getClipboardText*(): string {.raises: [].} =
  ## Retrieves the system clipboard text in UTF-8 format using thread-local fallback state.
  getClipboardText(gThreadClipboard)

proc clearClipboard*(ctx: var ClipboardContext): bool {.discardable, raises: [].} =
  ## Clears the system clipboard and context fallback buffer.
  ctx.fallbackBuffer = ""
  if ctx.forceFallback:
    return true
  when defined(windows):
    if not tryOpenClipboard(5):
      return false
    discard EmptyClipboard()
    discard CloseClipboard()
    return true
  else:
    return true

proc clearClipboard*(): bool {.discardable, raises: [].} =
  ## Clears the system clipboard and thread-local fallback buffer.
  clearClipboard(gThreadClipboard)
