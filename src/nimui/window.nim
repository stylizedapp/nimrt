## nimui/window — Native OS Window & Event Handling (Win32 + DPI Awareness)
##
## Strict invariants:
## - Pure native OS windowing without SDL/GLFW/Qt.
## - DPI-aware: SetProcessDpiAwarenessContext (Per-Monitor v2).
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

    # Messages
    WM_DESTROY*: uint32 = 0x0002
    WM_SIZE*: uint32 = 0x0005
    WM_CLOSE*: uint32 = 0x0010
    WM_CHAR*: uint32 = 0x0102
    WM_KEYDOWN*: uint32 = 0x0100
    WM_KEYUP*: uint32 = 0x0101
    WM_MOUSEMOVE*: uint32 = 0x0200
    WM_LBUTTONDOWN*: uint32 = 0x0201
    WM_LBUTTONUP*: uint32 = 0x0202
    WM_RBUTTONDOWN*: uint32 = 0x0204
    WM_RBUTTONUP*: uint32 = 0x0205
    WM_MOUSEWHEEL*: uint32 = 0x020A
    WM_DPICHANGED*: uint32 = 0x02E0

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
  proc WaitMessage(): BOOL {.stdcall, dynlib: "user32", importc: "WaitMessage", raises: [].}
  proc MsgWaitForMultipleObjectsEx(nCount: uint32, pHandles: pointer, dwMilliseconds: uint32, dwWakeMask: uint32, dwFlags: uint32): uint32 {.stdcall, dynlib: "user32", importc: "MsgWaitForMultipleObjectsEx", raises: [].}
  proc LoadCursorW(hInstance: HINSTANCE, lpCursorName: pointer): HCURSOR {.stdcall, dynlib: "user32", importc: "LoadCursorW", raises: [].}
  proc GetModuleHandleW(lpModuleName: pointer): HINSTANCE {.stdcall, dynlib: "kernel32", importc: "GetModuleHandleW", raises: [].}
  proc SetProcessDpiAwarenessContext(value: pointer): BOOL {.stdcall, dynlib: "user32", importc: "SetProcessDpiAwarenessContext", raises: [].}
  proc SetProcessDPIAware(): BOOL {.stdcall, dynlib: "user32", importc: "SetProcessDPIAware", raises: [].}
  proc AdjustWindowRectEx(lpRect: ptr RECT, dwStyle: uint32, bMenu: BOOL, dwExStyle: uint32): BOOL {.stdcall, dynlib: "user32", importc: "AdjustWindowRectEx", raises: [].}

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

  NativeWindow* = object
    hwnd*: HWND
    width*: int32
    height*: int32
    running*: bool
    pendingEvents*: seq[UiEvent]
    resized*: bool

# =============================================================================
# Win32 Window Procedure
# =============================================================================

when defined(windows):
  proc wndProc(hWnd: HWND, uMsg: uint32, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
    let pWin = cast[ptr NativeWindow](GetWindowLongPtrW(hWnd, GWLP_USERDATA))
    if pWin != nil:
      case uMsg
      of WM_SIZE:
        let w = int32(lParam and 0xFFFF)
        let h = int32((lParam shr 16) and 0xFFFF)
        pWin.width = w
        pWin.height = h
        pWin.resized = true
        pWin.pendingEvents.add(UiEvent(kind: ueResize, newWidth: w, newHeight: h))
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
        let r = Rune(wParam)
        pWin.pendingEvents.add(UiEvent(kind: ueChar, charVal: r))
        return 0

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

    # Get actual client area
    var rect: RECT
    if GetClientRect(hwnd, addr rect) != 0:
      result.width = rect.right - rect.left
      result.height = rect.bottom - rect.top

    # Set user data pointer
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
    # Bind this NativeWindow instance to HWND
    discard SetWindowLongPtrW(win.hwnd, GWLP_USERDATA, cast[LPARAM](addr win))
    while PeekMessageW(addr msg, nil, 0, 0, PM_REMOVE) != 0:
      discard TranslateMessage(addr msg)
      discard DispatchMessageW(addr msg)

  result = win.pendingEvents
  win.pendingEvents = @[]

proc waitEvents*(win: var NativeWindow, timeoutMs: int32 = 16) {.raises: [].} =
  when defined(windows):
    # Wait until a message is posted or timeout elapses
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
