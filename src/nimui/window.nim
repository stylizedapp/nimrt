## nimui/window — Native OS Window & Event Handling (Win32 + DPI Awareness + IME)
##
## Strict invariants:
## - Pure native OS windowing without SDL/GLFW/Qt.
## - DPI-aware: SetProcessDpiAwarenessContext (Per-Monitor v2) + GetDpiForWindow + WM_DPICHANGED.
## - Minimized window tracking (IsIconic / SIZE_MINIMIZED / 0x0 client extent).
## - Basic Win32 IME CJK composition & GCS_RESULTSTR UTF-16 -> UTF-8 -> Rune dispatch.
## - Mouse, keyboard, scroll, and resize event dispatch.
## - 0% CPU/GPU idle wait via MsgWaitForMultipleObjectsEx / WaitMessage.
## - Live RAM working set query via psapi GetProcessMemoryInfo.

import std/strformat
import ../corex/unicode
export unicode

when defined(windows):
  import std/widestrs

  type
    HWND* = pointer
    HINSTANCE* = pointer
    HICON* = pointer
    HCURSOR* = pointer
    HBRUSH* = pointer
    HIMC* = pointer
    WPARAM* = uint
    LPARAM* = int
    LRESULT* = int
    BOOL* = int32
    DWORD* = uint32
    UINT* = uint32
    ATOM* = uint16

    WNDPROC* = proc(hWnd: HWND, uMsg: uint32, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.}

    POINT* = object
      x*: int32
      y*: int32

    MSG* = object
      hWnd*: HWND
      message*: uint32
      wParam*: WPARAM
      lParam*: LPARAM
      time*: uint32
      pt*: POINT

    RECT* = object
      left*: int32
      top*: int32
      right*: int32
      bottom*: int32

    WNDCLASSEXW* = object
      cbSize*: uint32
      style*: uint32
      lpfnWndProc*: WNDPROC
      cbClsExtra*: int32
      cbWndExtra*: int32
      hInstance*: HINSTANCE
      hIcon*: HICON
      hCursor*: HCURSOR
      hbrBackground*: HBRUSH
      lpszMenuName*: pointer
      lpszClassName*: WideCString
      hIconSm*: HICON

    PROCESS_MEMORY_COUNTERS* = object
      cb*: uint32
      pageFaultCount*: uint32
      peakWorkingSetSize*: uint
      workingSetSize*: uint
      quotaPeakPagedPoolUsage*: uint
      quotaPagedPoolUsage*: uint
      quotaPeakNonPagedPoolUsage*: uint
      quotaNonPagedPoolUsage*: uint
      pagefileUsage*: uint
      peakPagefileUsage*: uint

  const
    WS_OVERLAPPEDWINDOW*: uint32 = 0x00CF0000
    WS_VISIBLE*: uint32 = 0x10000000
    CW_USEDEFAULT*: int32 = cast[int32](0x80000000'u32)
    CS_HREDRAW*: uint32 = 0x0002
    CS_VREDRAW*: uint32 = 0x0001
    CS_OWNDC*: uint32 = 0x0020
    SW_SHOW*: int32 = 5
    PM_REMOVE*: uint32 = 0x0001
    GWLP_USERDATA*: int32 = -21
    SIZE_MINIMIZED*: uint = 1
    SWP_NOZORDER*: uint32 = 0x0004
    SWP_NOACTIVATE*: uint32 = 0x0010

    # Messages
    WM_DESTROY*: uint32 = 0x0002
    WM_SIZE*: uint32 = 0x0005
    WM_CLOSE*: uint32 = 0x0010
    WM_CHAR*: uint32 = 0x0102
    WM_KEYDOWN*: uint32 = 0x0100
    WM_KEYUP*: uint32 = 0x0101
    WM_IME_STARTCOMPOSITION*: uint32 = 0x010D
    WM_IME_ENDCOMPOSITION*: uint32 = 0x010E
    WM_IME_COMPOSITION*: uint32 = 0x010F
    WM_MOUSEMOVE*: uint32 = 0x0200
    WM_LBUTTONDOWN*: uint32 = 0x0201
    WM_LBUTTONUP*: uint32 = 0x0202
    WM_RBUTTONDOWN*: uint32 = 0x0204
    WM_RBUTTONUP*: uint32 = 0x0205
    WM_MOUSEWHEEL*: uint32 = 0x020A
    WM_DPICHANGED*: uint32 = 0x02E0

    # IME Composition flags
    GCS_COMPSTR*: uint32 = 0x0008
    GCS_RESULTSTR*: uint32 = 0x0800

    # Key codes
    VK_BACK*: uint32 = 0x08
    VK_TAB*: uint32 = 0x09
    VK_RETURN*: uint32 = 0x0D
    VK_SHIFT*: uint32 = 0x10
    VK_CONTROL*: uint32 = 0x11
    VK_ESCAPE*: uint32 = 0x1B
    VK_END*: uint32 = 0x23
    VK_HOME*: uint32 = 0x24
    VK_LEFT*: uint32 = 0x25
    VK_UP*: uint32 = 0x26
    VK_RIGHT*: uint32 = 0x27
    VK_DOWN*: uint32 = 0x28
    VK_DELETE*: uint32 = 0x2E

  proc DefWindowProcW(hWnd: HWND, Msg: uint32, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall, dynlib: "user32", importc: "DefWindowProcW", raises: [].}
  proc GetKeyState(nVirtKey: int32): int16 {.stdcall, dynlib: "user32", importc: "GetKeyState", raises: [].}
  proc RegisterClassExW(lpwcx: ptr WNDCLASSEXW): ATOM {.stdcall, dynlib: "user32", importc: "RegisterClassExW", raises: [].}
  proc CreateWindowExW(
    dwExStyle: uint32, lpClassName: WideCString, lpWindowName: WideCString,
    dwStyle: uint32, X, Y, nWidth, nHeight: int32,
    hWndParent: HWND, hMenu: pointer, hInstance: HINSTANCE, lpParam: pointer
  ): HWND {.stdcall, dynlib: "user32", importc: "CreateWindowExW", raises: [].}
  proc ShowWindow(hWnd: HWND, nCmdShow: int32): BOOL {.stdcall, dynlib: "user32", importc: "ShowWindow", raises: [].}
  proc UpdateWindow(hWnd: HWND): BOOL {.stdcall, dynlib: "user32", importc: "UpdateWindow", raises: [].}
  proc DestroyWindow(hWnd: HWND): BOOL {.stdcall, dynlib: "user32", importc: "DestroyWindow", raises: [].}
  proc PeekMessageW(lpMsg: ptr MSG, hWnd: HWND, wMsgFilterMin, wMsgFilterMax, wRemoveMsg: uint32): BOOL {.stdcall, dynlib: "user32", importc: "PeekMessageW", raises: [].}
  proc TranslateMessage(lpMsg: ptr MSG): BOOL {.stdcall, dynlib: "user32", importc: "TranslateMessage", raises: [].}
  proc DispatchMessageW(lpMsg: ptr MSG): LRESULT {.stdcall, dynlib: "user32", importc: "DispatchMessageW", raises: [].}
  proc PostQuitMessage(nExitCode: int32) {.stdcall, dynlib: "user32", importc: "PostQuitMessage", raises: [].}
  proc SetWindowTextW(hWnd: HWND, lpString: WideCString): BOOL {.stdcall, dynlib: "user32", importc: "SetWindowTextW", raises: [].}
  proc GetClientRect(hWnd: HWND, lpRect: ptr RECT): BOOL {.stdcall, dynlib: "user32", importc: "GetClientRect", raises: [].}
  proc SetWindowLongPtrW(hWnd: HWND, nIndex: int32, dwNewLong: LPARAM): LPARAM {.stdcall, dynlib: "user32", importc: "SetWindowLongPtrW", raises: [].}
  proc GetWindowLongPtrW(hWnd: HWND, nIndex: int32): LPARAM {.stdcall, dynlib: "user32", importc: "GetWindowLongPtrW", raises: [].}
  proc MsgWaitForMultipleObjectsEx(nCount: uint32, pHandles: pointer, dwMilliseconds: uint32, dwWakeMask: uint32, dwFlags: uint32): uint32 {.stdcall, dynlib: "user32", importc: "MsgWaitForMultipleObjectsEx", raises: [].}
  proc LoadCursorW(hInstance: HINSTANCE, lpCursorName: pointer): HCURSOR {.stdcall, dynlib: "user32", importc: "LoadCursorW", raises: [].}
  proc GetModuleHandleW(lpModuleName: pointer): HINSTANCE {.stdcall, dynlib: "kernel32", importc: "GetModuleHandleW", raises: [].}
  proc SetProcessDpiAwarenessContext(value: pointer): BOOL {.stdcall, dynlib: "user32", importc: "SetProcessDpiAwarenessContext", raises: [].}
  proc SetProcessDPIAware(): BOOL {.stdcall, dynlib: "user32", importc: "SetProcessDPIAware", raises: [].}
  proc GetDpiForWindow(hWnd: HWND): UINT {.stdcall, dynlib: "user32", importc: "GetDpiForWindow", raises: [].}
  proc SetWindowPos(hWnd: HWND, hWndInsertAfter: HWND, X, Y, cx, cy: int32, uFlags: UINT): BOOL {.stdcall, dynlib: "user32", importc: "SetWindowPos", raises: [].}
  proc IsIconic(hWnd: HWND): BOOL {.stdcall, dynlib: "user32", importc: "IsIconic", raises: [].}
  proc AdjustWindowRectEx(lpRect: ptr RECT, dwStyle: uint32, bMenu: BOOL, dwExStyle: uint32): BOOL {.stdcall, dynlib: "user32", importc: "AdjustWindowRectEx", raises: [].}

  # IME (imm32)
  proc ImmGetContext(hWnd: HWND): HIMC {.stdcall, dynlib: "imm32", importc: "ImmGetContext", raises: [].}
  proc ImmReleaseContext(hWnd: HWND, hIMC: HIMC): BOOL {.stdcall, dynlib: "imm32", importc: "ImmReleaseContext", raises: [].}
  proc ImmGetCompositionStringW(hIMC: HIMC, dwIndex: DWORD, lpBuf: pointer, dwBufLen: DWORD): int32 {.stdcall, dynlib: "imm32", importc: "ImmGetCompositionStringW", raises: [].}

  # PSAPI
  proc GetProcessMemoryInfo(hProcess: pointer, ppsmps: ptr PROCESS_MEMORY_COUNTERS, cb: uint32): BOOL {.stdcall, dynlib: "psapi", importc: "GetProcessMemoryInfo", raises: [].}
  proc GetCurrentProcess(): pointer {.stdcall, dynlib: "kernel32", importc: "GetCurrentProcess", raises: [].}

type
  UiEventKind* = enum
    ueMouseMove
    ueMouseDown
    ueMouseUp
    ueRightMouseDown
    ueRightMouseUp
    ueMouseWheel
    ueChar
    ueKeyDown
    ueResize

  UiEvent* = object
    kind*: UiEventKind
    mouseX*: float32
    mouseY*: float32
    wheelDelta*: float32
    charVal*: Rune
    keyCode*: uint32
    ctrlDown*: bool
    shiftDown*: bool
    newWidth*: int32
    newHeight*: int32
    dpiScale*: float32

  NativeWindow* = object
    hwnd*: pointer
    width*: int32
    height*: int32
    dpi*: uint32
    dpiScale*: float32
    dpiChanged*: bool
    minimized*: bool
    running*: bool
    pendingEvents*: seq[UiEvent]
    resized*: bool
    pendingHighSurrogate*: uint16
    imeComposing*: bool
    imeCompositionText*: string

# =============================================================================
# Cross-Platform UTF-16 -> UTF-8 IME Helper
# =============================================================================

proc decodeImeUtf16*(units: openArray[uint16]): string {.raises: [].} =
  ## Converts a UTF-16 code unit sequence (including surrogate pairs) to UTF-8.
  result = newStringOfCap(units.len * 3)
  var i = 0
  while i < units.len:
    let w1 = units[i]
    inc(i)
    if w1 == 0'u16:
      break
    if w1 >= 0xD800'u16 and w1 <= 0xDBFF'u16:
      if i < units.len:
        let w2 = units[i]
        if w2 >= 0xDC00'u16 and w2 <= 0xDFFF'u16:
          inc(i)
          let cp = 0x10000'u32 + (((uint32(w1) and 0x3FF'u32) shl 10) or (uint32(w2) and 0x3FF'u32))
          result.add(toUTF8(Rune(cp)))
          continue
      result.add(toUTF8(Rune(0xFFFD'u32)))
    elif w1 >= 0xDC00'u16 and w1 <= 0xDFFF'u16:
      result.add(toUTF8(Rune(0xFFFD'u32)))
    else:
      result.add(toUTF8(Rune(w1)))

proc queryDpiScale*(dpi: uint32): float32 {.inline, raises: [].} =
  if dpi == 0'u32: 1.0f else: float32(dpi) / 96.0f

proc isMinimized*(win: NativeWindow): bool {.inline, raises: [].} =
  if win.minimized or win.width <= 0 or win.height <= 0:
    return true
  when defined(windows):
    if win.hwnd != nil and IsIconic(win.hwnd) != 0:
      return true
  false

proc getDpiScale*(win: NativeWindow): float32 {.inline, raises: [].} =
  if win.dpiScale > 0.1f: win.dpiScale else: 1.0f

proc toLogicalPx*(win: NativeWindow, physicalPx: float32): float32 {.inline, raises: [].} =
  physicalPx / win.getDpiScale()

proc toPhysicalPx*(win: NativeWindow, logicalPx: float32): float32 {.inline, raises: [].} =
  logicalPx * win.getDpiScale()

# =============================================================================
# Win32 Window Procedure
# =============================================================================

when defined(windows):
  proc readImeStringUtf8(hWnd: HWND, dwIndex: uint32): string {.raises: [].} =
    let hImc = ImmGetContext(hWnd)
    if hImc == nil:
      return ""
    defer:
      discard ImmReleaseContext(hWnd, hImc)
    let bytesLen = ImmGetCompositionStringW(hImc, dwIndex, nil, 0'u32)
    if bytesLen <= 0:
      return ""
    let unitCount = int(bytesLen) div 2
    if unitCount <= 0:
      return ""
    var buf = newSeq[uint16](unitCount)
    let readBytes = ImmGetCompositionStringW(hImc, dwIndex, addr buf[0], DWORD(bytesLen))
    if readBytes <= 0:
      return ""
    let actualUnits = min(unitCount, int(readBytes) div 2)
    decodeImeUtf16(buf.toOpenArray(0, actualUnits - 1))

  proc wndProc(hWnd: HWND, uMsg: uint32, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
    let pWin = cast[ptr NativeWindow](GetWindowLongPtrW(hWnd, GWLP_USERDATA))
    if pWin != nil:
      case uMsg
      of WM_SIZE:
        let w = int32(lParam and 0xFFFF)
        let h = int32((lParam shr 16) and 0xFFFF)
        pWin.width = w
        pWin.height = h
        pWin.minimized = (wParam == SIZE_MINIMIZED or w <= 0 or h <= 0)
        pWin.resized = true
        pWin.pendingEvents.add(UiEvent(kind: ueResize, newWidth: w, newHeight: h))
        return 0

      of WM_DPICHANGED:
        let newDpi = uint32(wParam and 0xFFFF)
        pWin.dpi = if newDpi > 0'u32: newDpi else: 96'u32
        pWin.dpiScale = queryDpiScale(pWin.dpi)
        pWin.dpiChanged = true
        let suggested = cast[ptr RECT](lParam)
        if suggested != nil:
          discard SetWindowPos(
            hWnd, nil,
            suggested.left, suggested.top,
            suggested.right - suggested.left,
            suggested.bottom - suggested.top,
            SWP_NOZORDER or SWP_NOACTIVATE
          )
        pWin.resized = true
        pWin.pendingEvents.add(UiEvent(
          kind: ueResize,
          newWidth: pWin.width,
          newHeight: pWin.height,
          dpiScale: pWin.dpiScale
        ))
        return 0

      of WM_MOUSEMOVE:
        let x = float32(cast[int16](lParam and 0xFFFF))
        let y = float32(cast[int16]((lParam shr 16) and 0xFFFF))
        pWin.pendingEvents.add(UiEvent(kind: ueMouseMove, mouseX: x, mouseY: y))
        return 0

      of WM_LBUTTONDOWN:
        let x = float32(cast[int16](lParam and 0xFFFF))
        let y = float32(cast[int16]((lParam shr 16) and 0xFFFF))
        let shift = GetKeyState(0x10'i32) < 0
        let ctrl = GetKeyState(0x11'i32) < 0
        pWin.pendingEvents.add(UiEvent(kind: ueMouseDown, mouseX: x, mouseY: y, ctrlDown: ctrl, shiftDown: shift))
        return 0

      of WM_LBUTTONUP:
        let x = float32(cast[int16](lParam and 0xFFFF))
        let y = float32(cast[int16]((lParam shr 16) and 0xFFFF))
        pWin.pendingEvents.add(UiEvent(kind: ueMouseUp, mouseX: x, mouseY: y))
        return 0

      of WM_RBUTTONDOWN:
        let x = float32(cast[int16](lParam and 0xFFFF))
        let y = float32(cast[int16]((lParam shr 16) and 0xFFFF))
        pWin.pendingEvents.add(UiEvent(kind: ueRightMouseDown, mouseX: x, mouseY: y))
        return 0

      of WM_RBUTTONUP:
        let x = float32(cast[int16](lParam and 0xFFFF))
        let y = float32(cast[int16]((lParam shr 16) and 0xFFFF))
        pWin.pendingEvents.add(UiEvent(kind: ueRightMouseUp, mouseX: x, mouseY: y))
        return 0

      of WM_MOUSEWHEEL:
        let delta = float32(cast[int16]((wParam shr 16) and 0xFFFF)) / 120.0f
        pWin.pendingEvents.add(UiEvent(kind: ueMouseWheel, wheelDelta: delta))
        return 0

      of WM_CHAR:
        let unit = uint16(wParam and 0xFFFF)
        if unit >= 0xD800'u16 and unit <= 0xDBFF'u16:
          pWin.pendingHighSurrogate = unit
        elif unit >= 0xDC00'u16 and unit <= 0xDFFF'u16:
          if pWin.pendingHighSurrogate != 0'u16:
            let cp = 0x10000'u32 + (((uint32(pWin.pendingHighSurrogate) and 0x3FF'u32) shl 10) or (uint32(unit) and 0x3FF'u32))
            pWin.pendingHighSurrogate = 0'u16
            pWin.pendingEvents.add(UiEvent(kind: ueChar, charVal: Rune(cp)))
        else:
          pWin.pendingHighSurrogate = 0'u16
          pWin.pendingEvents.add(UiEvent(kind: ueChar, charVal: Rune(unit)))
        return 0

      of WM_IME_STARTCOMPOSITION:
        pWin.imeComposing = true
        pWin.imeCompositionText = ""
        # Let DefWindowProcW manage the OS IME candidate window position
        return DefWindowProcW(hWnd, uMsg, wParam, lParam)

      of WM_IME_COMPOSITION:
        let flags = uint32(lParam)
        if (flags and GCS_COMPSTR) != 0'u32:
          pWin.imeComposing = true
          pWin.imeCompositionText = readImeStringUtf8(hWnd, GCS_COMPSTR)
        if (flags and GCS_RESULTSTR) != 0'u32:
          let committed = readImeStringUtf8(hWnd, GCS_RESULTSTR)
          pWin.imeCompositionText = ""
          for r in runes(committed):
            pWin.pendingEvents.add(UiEvent(kind: ueChar, charVal: r))
          # Returning 0 consumes GCS_RESULTSTR so DefWindowProcW does not duplicate WM_IME_CHAR/WM_CHAR
          return 0
        return DefWindowProcW(hWnd, uMsg, wParam, lParam)

      of WM_IME_ENDCOMPOSITION:
        pWin.imeComposing = false
        pWin.imeCompositionText = ""
        return DefWindowProcW(hWnd, uMsg, wParam, lParam)

      of WM_KEYDOWN:
        let code = uint32(wParam)
        let shift = GetKeyState(0x10'i32) < 0
        let ctrl = GetKeyState(0x11'i32) < 0
        pWin.pendingEvents.add(UiEvent(kind: ueKeyDown, keyCode: code, ctrlDown: ctrl, shiftDown: shift))
        return 0

      of WM_CLOSE:
        pWin.running = false
        return 0

      of WM_DESTROY:
        pWin.running = false
        PostQuitMessage(0)
        return 0

      else:
        discard

    DefWindowProcW(hWnd, uMsg, wParam, lParam)

# =============================================================================
# Window Lifecycle
# =============================================================================

proc initNativeWindow*(title: string, width, height: int32): NativeWindow {.raises: [].} =
  result.width = width
  result.height = height
  result.dpi = 96'u32
  result.dpiScale = 1.0f
  result.minimized = false
  result.running = true
  result.pendingEvents = @[]
  result.resized = false

  when defined(windows):
    # Set Per-Monitor v2 DPI Awareness
    let DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = cast[pointer](-4)
    if SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0:
      discard SetProcessDPIAware()

    let hInstance = GetModuleHandleW(nil)
    let className = newWideCString("NimUI_WindowClass")

    var wc = WNDCLASSEXW(
      cbSize: uint32(sizeof(WNDCLASSEXW)),
      style: CS_HREDRAW or CS_VREDRAW or CS_OWNDC,
      lpfnWndProc: wndProc,
      cbClsExtra: 0,
      cbWndExtra: 0,
      hInstance: hInstance,
      hIcon: nil,
      hCursor: LoadCursorW(nil, cast[pointer](32512)), # IDC_ARROW
      hbrBackground: nil,
      lpszMenuName: nil,
      lpszClassName: className,
      hIconSm: nil
    )
    discard RegisterClassExW(addr wc)

    let winStyle = WS_OVERLAPPEDWINDOW or WS_VISIBLE
    var wr = RECT(left: 0, top: 0, right: width, bottom: height)
    discard AdjustWindowRectEx(addr wr, winStyle, 0, 0)
    let winW = wr.right - wr.left
    let winH = wr.bottom - wr.top

    let wTitle = newWideCString(title)
    let hwnd = CreateWindowExW(
      0, className, wTitle,
      winStyle,
      CW_USEDEFAULT, CW_USEDEFAULT, winW, winH,
      nil, nil, hInstance, nil
    )

    result.hwnd = hwnd

    if hwnd != nil:
      let winDpi = GetDpiForWindow(hwnd)
      if winDpi > 0'u32:
        result.dpi = winDpi
        result.dpiScale = queryDpiScale(winDpi)

      var rect: RECT
      if GetClientRect(hwnd, addr rect) != 0:
        result.width = rect.right - rect.left
        result.height = rect.bottom - rect.top
      result.minimized = (IsIconic(hwnd) != 0 or result.width <= 0 or result.height <= 0)

      discard SetWindowLongPtrW(hwnd, GWLP_USERDATA, cast[LPARAM](unsafeAddr result))
      discard ShowWindow(hwnd, SW_SHOW)
      discard UpdateWindow(hwnd)

proc setTitle*(win: NativeWindow, title: string) {.raises: [].} =
  when defined(windows):
    if win.hwnd != nil:
      let wTitle = newWideCString(title)
      discard SetWindowTextW(win.hwnd, wTitle)

proc pollEvents*(win: var NativeWindow): seq[UiEvent] {.raises: [].} =
  when defined(windows):
    var msg: MSG
    if win.hwnd != nil:
      discard SetWindowLongPtrW(win.hwnd, GWLP_USERDATA, cast[LPARAM](addr win))
    while PeekMessageW(addr msg, nil, 0, 0, PM_REMOVE) != 0:
      discard TranslateMessage(addr msg)
      discard DispatchMessageW(addr msg)

  result = win.pendingEvents
  win.pendingEvents = @[]

proc waitEvents*(win: var NativeWindow, timeoutMs: int32 = 16) {.raises: [].} =
  when defined(windows):
    discard MsgWaitForMultipleObjectsEx(0, nil, uint32(timeoutMs), 0x04FF, 0) # QS_ALLINPUT

proc close*(win: var NativeWindow) {.raises: [].} =
  win.running = false
  when defined(windows):
    if win.hwnd != nil:
      discard DestroyWindow(win.hwnd)
      win.hwnd = nil

# =============================================================================
# Diagnostic Memory Stats
# =============================================================================

proc getProcessMemoryBytes*(): uint64 {.raises: [].} =
  when defined(windows):
    var counters: PROCESS_MEMORY_COUNTERS
    counters.cb = uint32(sizeof(PROCESS_MEMORY_COUNTERS))
    if GetProcessMemoryInfo(GetCurrentProcess(), addr counters, counters.cb) != 0:
      return uint64(counters.workingSetSize)
  0'u64

proc formatBytes*(bytes: uint64): string =
  if bytes < 1024:
    return $bytes & " B"
  elif bytes < 1024 * 1024:
    return $(bytes div 1024) & " KB"
  else:
    let mb = float(bytes) / (1024.0 * 1024.0)
    return &"{mb:.1f} MB"
