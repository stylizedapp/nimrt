## apps/everything/src/win32_gui — Pure Win32 High-Performance GUI for Everything-Nim
##
## Implements a high-craft Win32 UI without external UI frameworks (pure Win32 FFI):
## - Main Window (CreateWindowExW / RegisterClassExW, resizable, WM_SIZE).
## - Top search box (WC_EDIT) with 50ms timer debounce.
## - Virtual List View (SysListView32 / LVS_REPORT / LVS_OWNERDATA) with Name, Path, Size columns.
## - Double-click ShellExecuteW execution.
## - Right-click TrackPopupMenu context menu ("Open", "Open folder", "Copy path").
## - System tray icon (Shell_NotifyIconW) with minimize-to-tray on minimize/close.
## - Global hotkey (RegisterHotKey, e.g. Win+E) to toggle visibility.
## - Pure Win32 clipboard operations (CF_UNICODETEXT).

import std/[os, strutils, widestrs]
import ./config

# =============================================================================
# Logging
# =============================================================================

proc logGui*(msg: string) =
  try:
    let path = getGuiLogPath()
    let dir = splitFile(path).dir
    if not dirExists(dir):
      createDir(dir)
    let f = open(path, fmAppend)
    f.writeLine(msg)
    f.close()
  except CatchableError:
    discard

# =============================================================================
# 1. Win32 Types and Constants
# =============================================================================

type
  HANDLE* = pointer
  HWND* = pointer
  HINSTANCE* = pointer
  HDC* = pointer
  HICON* = pointer
  HCURSOR* = pointer
  HBRUSH* = pointer
  HMENU* = pointer
  HFONT* = pointer
  HGLOBAL* = pointer
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

  RECT* = object
    left*: int32
    top*: int32
    right*: int32
    bottom*: int32

  MSG* = object
    hWnd*: HWND
    message*: uint32
    wParam*: WPARAM
    lParam*: LPARAM
    time*: uint32
    pt*: POINT

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
    lpszMenuName*: WideCString
    lpszClassName*: WideCString
    hIconSm*: HICON

  CREATESTRUCTW* = object
    lpCreateParams*: pointer
    hInstance*: HINSTANCE
    hMenu*: HMENU
    hwndParent*: HWND
    cy*: int32
    cx*: int32
    y*: int32
    x*: int32
    style*: int32
    lpszName*: WideCString
    lpszClass*: WideCString
    dwExStyle*: DWORD

  NOTIFYICONDATAW* = object
    cbSize*: uint32
    hWnd*: HWND
    uID*: uint32
    uFlags*: uint32
    uCallbackMessage*: uint32
    hIcon*: HICON
    szTip*: array[128, uint16]
    dwState*: uint32
    dwStateMask*: uint32
    szInfo*: array[256, uint16]
    uTimeoutOrVersion*: uint32
    szInfoTitle*: array[64, uint16]
    dwInfoFlags*: uint32
    guidItem*: array[16, byte]
    hBalloonIcon*: HICON

  NMHDR* = object
    hwndFrom*: HWND
    idFrom*: uint
    code*: uint32

  LVCOLUMNW* = object
    mask*: uint32
    fmt*: int32
    cx*: int32
    pszText*: WideCString
    cchTextMax*: int32
    iSubItem*: int32
    iImage*: int32
    iOrder*: int32
    cxMin*: int32
    cxDefault*: int32
    cxIdeal*: int32

  LVITEMW* = object
    mask*: uint32
    iItem*: int32
    iSubItem*: int32
    state*: uint32
    stateMask*: uint32
    pszText*: WideCString
    cchTextMax*: int32
    iImage*: int32
    lParam*: LPARAM
    iIndent*: int32
    iGroupId*: int32
    cColumns*: uint32
    puColumns*: ptr uint32
    piColFmt*: ptr int32
    iGroup*: int32

  NMLVDISPINFOW* = object
    hdr*: NMHDR
    item*: LVITEMW

  INITCOMMONCONTROLSEX* = object
    dwSize*: uint32
    dwICC*: uint32

const
  # Window Styles
  WS_OVERLAPPED* = 0x00000000'u32
  WS_CAPTION* = 0x00C00000'u32
  WS_SYSMENU* = 0x00080000'u32
  WS_THICKFRAME* = 0x00040000'u32
  WS_MINIMIZEBOX* = 0x00020000'u32
  WS_MAXIMIZEBOX* = 0x00010000'u32
  WS_OVERLAPPEDWINDOW* = WS_OVERLAPPED or WS_CAPTION or WS_SYSMENU or WS_THICKFRAME or WS_MINIMIZEBOX or WS_MAXIMIZEBOX
  WS_CLIPCHILDREN* = 0x02000000'u32
  WS_VISIBLE* = 0x10000000'u32
  WS_CHILD* = 0x40000000'u32
  WS_BORDER* = 0x00800000'u32
  WS_TABSTOP* = 0x00010000'u32

  WS_EX_CLIENTEDGE* = 0x00000200'u32
  WS_EX_APPWINDOW* = 0x00040000'u32

  # Edit Control Styles
  ES_AUTOHSCROLL* = 0x0080'u32

  # Window Messages
  WM_CREATE* = 0x0001'u32
  WM_DESTROY* = 0x0002'u32
  WM_SIZE* = 0x0005'u32
  WM_ACTIVATE* = 0x0006'u32
  WM_SETFOCUS* = 0x0007'u32
  WM_CLOSE* = 0x0010'u32
  WM_SETFONT* = 0x0030'u32
  WM_NOTIFY* = 0x004E'u32
  WM_COMMAND* = 0x0111'u32
  WM_TIMER* = 0x0113'u32
  WM_KEYDOWN* = 0x0100'u32
  WM_CHAR* = 0x0102'u32
  WM_HOTKEY* = 0x0312'u32
  WM_CONTEXTMENU* = 0x007B'u32
  WM_USER* = 0x0400'u32

  # Edit Messages
  EM_SETSEL* = 0x00B1'u32

  # Activate state
  WA_INACTIVE* = 0
  WA_ACTIVE* = 1
  WA_CLICKACTIVE* = 2

  WM_TRAYICON* = WM_USER + 100
  WM_INDEX_UPDATED* = WM_USER + 101

  # Mouse messages
  WM_LBUTTONDOWN* = 0x0201'u32
  WM_LBUTTONDBLCLK* = 0x0203'u32
  WM_RBUTTONUP* = 0x0205'u32

  # Edit Notifications
  EN_CHANGE* = 0x0300'u32

  # Size types
  SIZE_RESTORED* = 0
  SIZE_MINIMIZED* = 1

  # List View Styles
  LVS_REPORT* = 0x0001'u32
  LVS_SINGLESEL* = 0x0004'u32
  LVS_OWNERDATA* = 0x1000'u32

  # List View Extended Styles
  LVS_EX_GRIDLINES* = 0x00000001'u32
  LVS_EX_FULLROWSELECT* = 0x00000020'u32
  LVS_EX_DOUBLEBUFFER* = 0x00010000'u32

  # List View Messages
  LVM_FIRST* = 0x1000'u32
  LVM_SETITEMCOUNT* = LVM_FIRST + 47
  LVM_INSERTCOLUMNW* = LVM_FIRST + 97
  LVM_SETEXTENDEDLISTVIEWSTYLE* = LVM_FIRST + 54
  LVM_GETNEXTITEM* = LVM_FIRST + 12

  # List View Item Flags & Masks
  LVIF_TEXT* = 0x0001'u32
  LVCF_FMT* = 0x0001'u32
  LVCF_WIDTH* = 0x0002'u32
  LVCF_TEXT* = 0x0004'u32
  LVCF_SUBITEM* = 0x0008'u32

  LVCFMT_LEFT* = 0x0000'i32
  LVNI_SELECTED* = 0x0002'i32
  LVSICF_NOINVALIDATEALL* = 0x00000001'u32

  # Notification codes
  NM_DBLCLK* = cast[uint32](0 - 3)
  NM_RCLICK* = cast[uint32](0 - 5)
  LVN_FIRST* = cast[uint32](0 - 100)
  LVN_GETDISPINFOW* = cast[uint32](LVN_FIRST - 77)

  # Tray Icon
  NIM_ADD* = 0x00000000'u32
  NIM_MODIFY* = 0x00000001'u32
  NIM_DELETE* = 0x00000002'u32
  NIF_MESSAGE* = 0x00000001'u32
  NIF_ICON* = 0x00000002'u32
  NIF_TIP* = 0x00000004'u32

  # Menu Constants
  MF_STRING* = 0x00000000'u32
  MF_SEPARATOR* = 0x00000800'u32
  TPM_RIGHTBUTTON* = 0x0002'u32
  TPM_RETURNCMD* = 0x0100'u32

  # ShowWindow
  SW_HIDE* = 0
  SW_SHOWNORMAL* = 1
  SW_SHOW* = 5
  SW_RESTORE* = 9

  # Stock Objects & Icons
  DEFAULT_GUI_FONT* = 17
  COLOR_WINDOW* = 5
  IDC_ARROW* = cast[WideCString](32512)
  IDI_APPLICATION* = cast[WideCString](32512)

  # IDs
  HOTKEY_ID_MAIN* = 0x4556 # "EV"
  TIMER_DEBOUNCE_ID* = 1
  DEBOUNCE_DELAY_MS* = 50

  IDM_OPEN* = 1001
  IDM_OPEN_FOLDER* = 1002
  IDM_COPY_PATH* = 1003
  IDM_TRAY_SHOW* = 1004
  IDM_TRAY_EXIT* = 1005

  # Clipboard
  CF_UNICODETEXT* = 13'u32
  GMEM_MOVEABLE* = 0x0002'u32

  # ComCtl
  ICC_LISTVIEW_CLASSES* = 0x00000001'u32
  CW_USEDEFAULT* = cast[int32](0x80000000'u32)
  GWLP_USERDATA* = -21'i32

# =============================================================================
# 2. Win32 FFI Imports
# =============================================================================

proc registerClassExW*(lpwcx: ptr WNDCLASSEXW): ATOM {.
  stdcall, dynlib: "user32", importc: "RegisterClassExW", sideEffect.}

proc createWindowExW*(
  dwExStyle: DWORD,
  lpClassName: WideCString,
  lpWindowName: WideCString,
  dwStyle: DWORD,
  X, Y, nWidth, nHeight: int32,
  hWndParent: HWND,
  hMenu: HMENU,
  hInstance: HINSTANCE,
  lpParam: pointer
): HWND {.stdcall, dynlib: "user32", importc: "CreateWindowExW", sideEffect.}

proc defWindowProcW*(hWnd: HWND, uMsg: uint32, wParam: WPARAM, lParam: LPARAM): LRESULT {.
  stdcall, dynlib: "user32", importc: "DefWindowProcW", sideEffect.}

proc destroyWindow*(hWnd: HWND): BOOL {.
  stdcall, dynlib: "user32", importc: "DestroyWindow", sideEffect.}

proc showWindow*(hWnd: HWND, nCmdShow: int32): BOOL {.
  stdcall, dynlib: "user32", importc: "ShowWindow", sideEffect.}

proc updateWindow*(hWnd: HWND): BOOL {.
  stdcall, dynlib: "user32", importc: "UpdateWindow", sideEffect.}

proc moveWindow*(hWnd: HWND, X, Y, nWidth, nHeight: int32, bRepaint: BOOL): BOOL {.
  stdcall, dynlib: "user32", importc: "MoveWindow", sideEffect.}

proc setFocus*(hWnd: HWND): HWND {.
  stdcall, dynlib: "user32", importc: "SetFocus", sideEffect.}

proc isWindowVisible*(hWnd: HWND): BOOL {.
  stdcall, dynlib: "user32", importc: "IsWindowVisible", sideEffect.}

proc setForegroundWindow*(hWnd: HWND): BOOL {.
  stdcall, dynlib: "user32", importc: "SetForegroundWindow", sideEffect.}

proc getMessageW*(lpMsg: ptr MSG, hWnd: HWND, wMsgFilterMin, wMsgFilterMax: UINT): BOOL {.
  stdcall, dynlib: "user32", importc: "GetMessageW", sideEffect.}

proc translateMessage*(lpMsg: ptr MSG): BOOL {.
  stdcall, dynlib: "user32", importc: "TranslateMessage", sideEffect.}

proc dispatchMessageW*(lpMsg: ptr MSG): LRESULT {.
  stdcall, dynlib: "user32", importc: "DispatchMessageW", sideEffect.}

proc postQuitMessage*(nExitCode: int32) {.
  stdcall, dynlib: "user32", importc: "PostQuitMessage", sideEffect.}

proc postMessageW*(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM): BOOL {.
  stdcall, dynlib: "user32", importc: "PostMessageW", sideEffect.}

proc sendMessageW*(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.
  stdcall, dynlib: "user32", importc: "SendMessageW", sideEffect.}

proc setTimer*(hWnd: HWND, nIDEvent: uint, uElapse: UINT, lpTimerFunc: pointer): uint {.
  stdcall, dynlib: "user32", importc: "SetTimer", sideEffect.}

proc killTimer*(hWnd: HWND, uIDEvent: uint): BOOL {.
  stdcall, dynlib: "user32", importc: "KillTimer", sideEffect.}

proc getWindowTextLengthW*(hWnd: HWND): int32 {.
  stdcall, dynlib: "user32", importc: "GetWindowTextLengthW", sideEffect.}

proc getWindowTextW*(hWnd: HWND, lpString: WideCString, nMaxCount: int32): int32 {.
  stdcall, dynlib: "user32", importc: "GetWindowTextW", sideEffect.}

proc invalidateRect*(hWnd: HWND, lpRect: ptr RECT, bErase: BOOL): BOOL {.
  stdcall, dynlib: "user32", importc: "InvalidateRect", sideEffect.}

proc loadCursorW*(hInstance: HINSTANCE, lpCursorName: WideCString): HCURSOR {.
  stdcall, dynlib: "user32", importc: "LoadCursorW", sideEffect.}

proc loadIconW*(hInstance: HINSTANCE, lpIconName: WideCString): HICON {.
  stdcall, dynlib: "user32", importc: "LoadIconW", sideEffect.}

proc registerHotKey*(hWnd: HWND, id: int32, fsModifiers: UINT, vk: UINT): BOOL {.
  stdcall, dynlib: "user32", importc: "RegisterHotKey", sideEffect.}

proc unregisterHotKey*(hWnd: HWND, id: int32): BOOL {.
  stdcall, dynlib: "user32", importc: "UnregisterHotKey", sideEffect.}

proc createPopupMenu*(): HMENU {.
  stdcall, dynlib: "user32", importc: "CreatePopupMenu", sideEffect.}

proc appendMenuW*(hMenu: HMENU, uFlags: UINT, uIDNewItem: uint, lpNewItem: WideCString): BOOL {.
  stdcall, dynlib: "user32", importc: "AppendMenuW", sideEffect.}

proc trackPopupMenu*(hMenu: HMENU, uFlags: UINT, x, y: int32, nReserved: int32, hWnd: HWND, prcRect: pointer): int32 {.
  stdcall, dynlib: "user32", importc: "TrackPopupMenu", sideEffect.}

proc destroyMenu*(hMenu: HMENU): BOOL {.
  stdcall, dynlib: "user32", importc: "DestroyMenu", sideEffect.}

proc getCursorPos*(lpPoint: ptr POINT): BOOL {.
  stdcall, dynlib: "user32", importc: "GetCursorPos", sideEffect.}

proc openClipboard*(hWndNewOwner: HWND): BOOL {.
  stdcall, dynlib: "user32", importc: "OpenClipboard", sideEffect.}

proc closeClipboard*(): BOOL {.
  stdcall, dynlib: "user32", importc: "CloseClipboard", sideEffect.}

proc emptyClipboard*(): BOOL {.
  stdcall, dynlib: "user32", importc: "EmptyClipboard", sideEffect.}

proc setClipboardData*(uFormat: UINT, hMem: HANDLE): HANDLE {.
  stdcall, dynlib: "user32", importc: "SetClipboardData", sideEffect.}

proc globalAlloc*(uFlags: UINT, dwBytes: uint): HANDLE {.
  stdcall, dynlib: "kernel32", importc: "GlobalAlloc", sideEffect.}

proc globalLock*(hMem: HANDLE): pointer {.
  stdcall, dynlib: "kernel32", importc: "GlobalLock", sideEffect.}

proc globalUnlock*(hMem: HANDLE): BOOL {.
  stdcall, dynlib: "kernel32", importc: "GlobalUnlock", sideEffect.}

proc getStockObject*(i: int32): pointer {.
  stdcall, dynlib: "gdi32", importc: "GetStockObject", sideEffect.}

proc initCommonControlsEx*(lpInitCtrls: ptr INITCOMMONCONTROLSEX): BOOL {.
  stdcall, dynlib: "comctl32", importc: "InitCommonControlsEx", sideEffect.}

proc shell_NotifyIconW*(dwMessage: DWORD, lpData: ptr NOTIFYICONDATAW): BOOL {.
  stdcall, dynlib: "shell32", importc: "Shell_NotifyIconW", sideEffect.}

proc shellExecuteW*(
  hwnd: HWND,
  lpOperation: WideCString,
  lpFile: WideCString,
  lpParameters: WideCString,
  lpDirectory: WideCString,
  nShowCmd: int32
): pointer {.stdcall, dynlib: "shell32", importc: "ShellExecuteW", sideEffect.}

when sizeof(pointer) == 8:
  proc setWindowLongPtrW*(hWnd: HWND, nIndex: int32, dwNewLong: int): int {.
    stdcall, dynlib: "user32", importc: "SetWindowLongPtrW", sideEffect.}
  proc getWindowLongPtrW*(hWnd: HWND, nIndex: int32): int {.
    stdcall, dynlib: "user32", importc: "GetWindowLongPtrW", sideEffect.}
else:
  proc setWindowLongPtrW*(hWnd: HWND, nIndex: int32, dwNewLong: int): int {.
    stdcall, dynlib: "user32", importc: "SetWindowLongW", sideEffect.}
  proc getWindowLongPtrW*(hWnd: HWND, nIndex: int32): int {.
    stdcall, dynlib: "user32", importc: "GetWindowLongW", sideEffect.}

# =============================================================================
# 3. Model & Debounce Pure Logic (Unit-Testable Headless)
# =============================================================================

type
  GuiItem* = object
    name*: string
    path*: string
    size*: int64
    isDir*: bool

  VirtualListModel* = object
    items*: seq[GuiItem]

  DebounceTracker* = object
    delayMs*: uint32
    isPending*: bool
    pendingQuery*: string
    lastFiredQuery*: string

  SearchCallback* = proc(query: string): seq[GuiItem] {.closure.}

proc formatFileSize*(bytes: int64): string =
  if bytes < 0: return ""
  if bytes < 1024:
    return $bytes & " B"
  elif bytes < 1024 * 1024:
    let kb = float(bytes) / 1024.0
    return kb.formatFloat(ffDecimal, 1) & " KB"
  elif bytes < 1024 * 1024 * 1024:
    let mb = float(bytes) / (1024.0 * 1024.0)
    return mb.formatFloat(ffDecimal, 2) & " MB"
  else:
    let gb = float(bytes) / (1024.0 * 1024.0 * 1024.0)
    return gb.formatFloat(ffDecimal, 2) & " GB"

proc getItemText*(model: VirtualListModel, row: int, col: int): string =
  if row < 0 or row >= model.items.len:
    return ""
  case col
  of 0: model.items[row].name
  of 1: model.items[row].path
  of 2:
    if model.items[row].isDir:
      "<DIR>"
    else:
      formatFileSize(model.items[row].size)
  else: ""

proc initDebounceTracker*(delayMs: uint32 = 50): DebounceTracker =
  DebounceTracker(delayMs: delayMs, isPending: false, pendingQuery: "", lastFiredQuery: "")

proc triggerDebounce*(tracker: var DebounceTracker, query: string) =
  tracker.isPending = true
  tracker.pendingQuery = query

proc onTimerFire*(tracker: var DebounceTracker): tuple[shouldSearch: bool, query: string] =
  if tracker.isPending:
    tracker.isPending = false
    tracker.lastFiredQuery = tracker.pendingQuery
    return (true, tracker.pendingQuery)
  return (false, "")

# =============================================================================
# 4. Clipboard & System Tray Helpers
# =============================================================================

proc setClipboardText*(text: string, hWnd: HWND = nil): bool =
  if openClipboard(hWnd) == 0:
    return false
  discard emptyClipboard()
  let wStr = newWideCString(text)
  let pW: WideCString = wStr
  let bytesCount = (text.len + 1) * 2
  let hMem = globalAlloc(GMEM_MOVEABLE, uint(bytesCount))
  if hMem.isNil:
    discard closeClipboard()
    return false
  let pMem = globalLock(hMem)
  if not pMem.isNil:
    copyMem(pMem, cast[pointer](pW), bytesCount)
    discard globalUnlock(hMem)
    discard setClipboardData(CF_UNICODETEXT, hMem)
  discard closeClipboard()
  return true

type
  TrayIcon* = object
    nid*: NOTIFYICONDATAW
    isAdded*: bool

proc initTrayIcon*(hWnd: HWND, tooltip: string = "Everything-Nim"): TrayIcon =
  result.nid.cbSize = uint32(sizeof(NOTIFYICONDATAW))
  result.nid.hWnd = hWnd
  result.nid.uID = 1
  result.nid.uFlags = NIF_MESSAGE or NIF_ICON or NIF_TIP
  result.nid.uCallbackMessage = WM_TRAYICON
  result.nid.hIcon = loadIconW(nil, IDI_APPLICATION)

  let wTip = newWideCString(tooltip)
  let pW: WideCString = wTip
  var i = 0
  while i < 127 and pW[i].uint16 != 0:
    result.nid.szTip[i] = pW[i].uint16
    inc(i)
  result.nid.szTip[i] = 0
  result.isAdded = false

proc addTrayIcon*(tray: var TrayIcon): bool =
  if not tray.isAdded:
    let res = shell_NotifyIconW(NIM_ADD, addr tray.nid)
    tray.isAdded = (res != 0)
    return tray.isAdded
  return true

proc removeTrayIcon*(tray: var TrayIcon): bool =
  if tray.isAdded:
    let res = shell_NotifyIconW(NIM_DELETE, addr tray.nid)
    tray.isAdded = false
    return res != 0
  return true

# =============================================================================
# 5. Application Window State & Event Handlers
# =============================================================================

type
  AppState* = object
    hWnd*: HWND
    hEdit*: HWND
    hListView*: HWND
    model*: VirtualListModel
    debounce*: DebounceTracker
    tray*: TrayIcon
    config*: Config
    searchCallback*: SearchCallback
    isExiting*: bool

proc addListViewColumn*(hList: HWND, colIndex: int32, title: string, width: int32) =
  var col: LVCOLUMNW
  col.mask = LVCF_TEXT or LVCF_WIDTH or LVCF_SUBITEM or LVCF_FMT
  col.fmt = LVCFMT_LEFT
  col.cx = width
  col.iSubItem = colIndex
  let wTitle = newWideCString(title)
  col.pszText = wTitle
  discard sendMessageW(hList, LVM_INSERTCOLUMNW, cast[WPARAM](colIndex), cast[LPARAM](addr col))

proc refreshResultsView*(state: ptr AppState) =
  if state.isNil or state.hListView.isNil: return
  logGui("SetItemCountEx(" & $state.model.items.len & ")")
  discard sendMessageW(state.hListView, LVM_SETITEMCOUNT, cast[WPARAM](state.model.items.len), cast[LPARAM](LVSICF_NOINVALIDATEALL))
  discard invalidateRect(state.hListView, nil, 1)

proc executeSearch*(state: ptr AppState, query: string) =
  if state.isNil: return
  if state.searchCallback != nil:
    state.model.items = state.searchCallback(query)
  logGui("search results=" & $state.model.items.len)
  state.refreshResultsView()

proc showResultsContextMenu*(state: ptr AppState, x, y: int32, selectedRow: int) =
  if state.isNil or selectedRow < 0 or selectedRow >= state.model.items.len:
    return

  let item = state.model.items[selectedRow]
  let hMenu = createPopupMenu()
  if hMenu.isNil: return

  let wOpen = newWideCString("Open")
  let wOpenFolder = newWideCString("Open folder")
  let wCopyPath = newWideCString("Copy path")

  discard appendMenuW(hMenu, MF_STRING, cast[uint](IDM_OPEN), wOpen)
  discard appendMenuW(hMenu, MF_STRING, cast[uint](IDM_OPEN_FOLDER), wOpenFolder)
  discard appendMenuW(hMenu, MF_STRING, cast[uint](IDM_COPY_PATH), wCopyPath)

  discard setForegroundWindow(state.hWnd)
  let cmd = trackPopupMenu(hMenu, TPM_RIGHTBUTTON or TPM_RETURNCMD, x, y, 0, state.hWnd, nil)
  discard destroyMenu(hMenu)

  case cmd
  of IDM_OPEN:
    let wPath = newWideCString(item.path)
    let wOp = newWideCString("open")
    discard shellExecuteW(state.hWnd, wOp, wPath, nil, nil, SW_SHOWNORMAL)
  of IDM_OPEN_FOLDER:
    let wExplorer = newWideCString("explorer.exe")
    let wParams = newWideCString("/select,\"" & item.path & "\"")
    let wOp = newWideCString("open")
    discard shellExecuteW(state.hWnd, wOp, wExplorer, wParams, nil, SW_SHOWNORMAL)
  of IDM_COPY_PATH:
    discard setClipboardText(item.path, state.hWnd)
  else:
    discard

proc showTrayContextMenu*(state: ptr AppState, x, y: int32) =
  if state.isNil: return
  let hMenu = createPopupMenu()
  if hMenu.isNil: return

  let wShow = newWideCString("Show Everything")
  let wExit = newWideCString("Exit")
  discard appendMenuW(hMenu, MF_STRING, cast[uint](IDM_TRAY_SHOW), wShow)
  discard appendMenuW(hMenu, MF_SEPARATOR, 0, nil)
  discard appendMenuW(hMenu, MF_STRING, cast[uint](IDM_TRAY_EXIT), wExit)

  discard setForegroundWindow(state.hWnd)
  let cmd = trackPopupMenu(hMenu, TPM_RIGHTBUTTON or TPM_RETURNCMD, x, y, 0, state.hWnd, nil)
  discard destroyMenu(hMenu)

  case cmd
  of IDM_TRAY_SHOW:
    discard showWindow(state.hWnd, SW_RESTORE)
    discard setForegroundWindow(state.hWnd)
  of IDM_TRAY_EXIT:
    state.isExiting = true
    discard destroyWindow(state.hWnd)
  else:
    discard

proc handleGetDispInfo(state: ptr AppState, lParam: LPARAM) =
  let dispInfo = cast[ptr NMLVDISPINFOW](lParam)
  if (dispInfo.item.mask and LVIF_TEXT) != 0:
    let row = dispInfo.item.iItem.int
    let col = dispInfo.item.iSubItem.int
    let text = state.model.getItemText(row, col)
    if text.len > 0 and not dispInfo.item.pszText.isNil and dispInfo.item.cchTextMax > 0:
      let wText = newWideCString(text)
      let pW: WideCString = wText
      var dest = cast[ptr UncheckedArray[uint16]](dispInfo.item.pszText)
      var i = 0
      let maxLen = dispInfo.item.cchTextMax.int - 1
      while i < maxLen and pW[i].uint16 != 0:
        dest[i] = pW[i].uint16
        inc(i)
      dest[i] = 0

proc wndProc*(hWnd: HWND, uMsg: uint32, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  if uMsg == WM_CREATE:
    let cs = cast[ptr CREATESTRUCTW](lParam)
    let state = cast[ptr AppState](cs.lpCreateParams)
    discard setWindowLongPtrW(hWnd, GWLP_USERDATA, cast[int](state))
    state.hWnd = hWnd

    # Register Common Controls for List View
    var icc = INITCOMMONCONTROLSEX(
      dwSize: uint32(sizeof(INITCOMMONCONTROLSEX)),
      dwICC: ICC_LISTVIEW_CLASSES
    )
    discard initCommonControlsEx(addr icc)

    # Standard modern GUI font
    let hFont = getStockObject(DEFAULT_GUI_FONT)

    # 1. Create Top Search Edit Box (WC_EDIT)
    let wEditClass = newWideCString("EDIT")
    state.hEdit = createWindowExW(
      WS_EX_CLIENTEDGE,
      wEditClass,
      nil,
      WS_CHILD or WS_VISIBLE or WS_BORDER or ES_AUTOHSCROLL or WS_TABSTOP,
      10, 10, 780, 26,
      hWnd,
      nil,
      cs.hInstance,
      nil
    )
    discard sendMessageW(state.hEdit, WM_SETFONT, cast[WPARAM](hFont), 1)

    # 2. Create Results List View (SysListView32 / LVS_REPORT / LVS_OWNERDATA)
    let wListClass = newWideCString("SysListView32")
    state.hListView = createWindowExW(
      0,
      wListClass,
      nil,
      WS_CHILD or WS_VISIBLE or LVS_REPORT or LVS_OWNERDATA or LVS_SINGLESEL or WS_BORDER or WS_TABSTOP,
      10, 42, 780, 500,
      hWnd,
      nil,
      cs.hInstance,
      nil
    )
    discard sendMessageW(state.hListView, WM_SETFONT, cast[WPARAM](hFont), 1)

    # List view extended styles (Full row select, double buffering for smooth flicker-free rendering)
    let exStyles = LVS_EX_FULLROWSELECT or LVS_EX_DOUBLEBUFFER or LVS_EX_GRIDLINES
    discard sendMessageW(state.hListView, LVM_SETEXTENDEDLISTVIEWSTYLE, cast[WPARAM](exStyles), cast[LPARAM](exStyles))

    # Add columns: Name (250px), Path (450px), Size (100px)
    addListViewColumn(state.hListView, 0, "Name", 250)
    addListViewColumn(state.hListView, 1, "Path", 450)
    addListViewColumn(state.hListView, 2, "Size", 100)

    # 3. System Tray Icon
    state.tray = initTrayIcon(hWnd, "Everything-Nim")
    discard state.tray.addTrayIcon()

    # 4. Global Hotkey (e.g. Win+E)
    let (mods, vk) = parseHotkey(state.config.hotkey)
    if vk != 0:
      discard registerHotKey(hWnd, HOTKEY_ID_MAIN, mods, vk)

    state.debounce = initDebounceTracker(DEBOUNCE_DELAY_MS)

    # Set focus to edit control and select all
    discard setFocus(state.hEdit)
    discard sendMessageW(state.hEdit, EM_SETSEL, 0, -1)
    logGui("WM_CREATE controls initialized, focus set to hEdit")
    return 0

  let state = cast[ptr AppState](getWindowLongPtrW(hWnd, GWLP_USERDATA))
  if state.isNil:
    return defWindowProcW(hWnd, uMsg, wParam, lParam)

  case uMsg
  of WM_SETFOCUS:
    if not state.hEdit.isNil:
      discard setFocus(state.hEdit)
      discard sendMessageW(state.hEdit, EM_SETSEL, 0, -1)
    return 0

  of WM_ACTIVATE:
    let fActive = cast[int16](wParam and 0xFFFF)
    if fActive != WA_INACTIVE and not state.hEdit.isNil:
      discard setFocus(state.hEdit)
      discard sendMessageW(state.hEdit, EM_SETSEL, 0, -1)
    return 0

  of WM_CHAR:
    if not state.hEdit.isNil:
      discard setFocus(state.hEdit)
      discard sendMessageW(state.hEdit, WM_CHAR, wParam, lParam)
      return 0
    return defWindowProcW(hWnd, uMsg, wParam, lParam)

  of WM_SIZE:
    let width = cast[int16](lParam and 0xFFFF).int32
    let height = cast[int16]((lParam shr 16) and 0xFFFF).int32

    if wParam == SIZE_MINIMIZED:
      # Minimize to tray on minimize
      discard showWindow(hWnd, SW_HIDE)
      return 0

    if not state.hEdit.isNil and not state.hListView.isNil:
      discard moveWindow(state.hEdit, 10, 10, width - 20, 26, 1)
      discard moveWindow(state.hListView, 10, 42, width - 20, max(0, height - 52), 1)
    return 0

  of WM_COMMAND:
    let notif = (wParam shr 16) and 0xFFFF
    if notif == EN_CHANGE and lParam == cast[LPARAM](state.hEdit):
      # Trigger 50ms debounce timer
      let textLen = getWindowTextLengthW(state.hEdit)
      var wBuf = newSeq[uint16](textLen + 1)
      let pW = cast[WideCString](addr wBuf[0])
      discard getWindowTextW(state.hEdit, pW, textLen + 1)
      let query = $pW
      logGui("EN_CHANGE query=" & query)
      state.debounce.triggerDebounce(query)
      discard setTimer(hWnd, uint(TIMER_DEBOUNCE_ID), DEBOUNCE_DELAY_MS, nil)
      return 0

  of WM_TIMER:
    if wParam == uint(TIMER_DEBOUNCE_ID):
      discard killTimer(hWnd, uint(TIMER_DEBOUNCE_ID))
      let (shouldSearch, query) = state.debounce.onTimerFire()
      if shouldSearch:
        logGui("WM_TIMER fired, search query=" & query)
        state.executeSearch(query)
      return 0

  of WM_NOTIFY:
    let nmhdr = cast[ptr NMHDR](lParam)
    if nmhdr.hwndFrom == state.hListView:
      if nmhdr.code == LVN_GETDISPINFOW:
        handleGetDispInfo(state, lParam)
        return 0
      elif nmhdr.code == NM_DBLCLK:
        let sel = sendMessageW(state.hListView, LVM_GETNEXTITEM, cast[WPARAM](-1), cast[LPARAM](LVNI_SELECTED))
        if sel >= 0 and sel < state.model.items.len:
          let wPath = newWideCString(state.model.items[sel].path)
          let wOp = newWideCString("open")
          discard shellExecuteW(hWnd, wOp, wPath, nil, nil, SW_SHOWNORMAL)
        return 0

  of WM_CONTEXTMENU:
    let x = cast[int16](lParam and 0xFFFF).int32
    let y = cast[int16]((lParam shr 16) and 0xFFFF).int32
    let sel = sendMessageW(state.hListView, LVM_GETNEXTITEM, cast[WPARAM](-1), cast[LPARAM](LVNI_SELECTED))
    if sel >= 0 and sel < state.model.items.len:
      state.showResultsContextMenu(x, y, int(sel))
      return 0

  of WM_TRAYICON:
    let evt = lParam.uint32
    case evt
    of WM_LBUTTONDOWN, WM_LBUTTONDBLCLK:
      discard showWindow(hWnd, SW_RESTORE)
      discard setForegroundWindow(hWnd)
      discard setFocus(state.hEdit)
    of WM_RBUTTONUP:
      var pt: POINT
      discard getCursorPos(addr pt)
      state.showTrayContextMenu(pt.x, pt.y)
    else:
      discard
    return 0

  of WM_HOTKEY:
    if wParam == uint(HOTKEY_ID_MAIN):
      if isWindowVisible(hWnd) != 0:
        discard showWindow(hWnd, SW_HIDE)
      else:
        discard showWindow(hWnd, SW_SHOW)
        discard showWindow(hWnd, SW_RESTORE)
        discard setForegroundWindow(hWnd)
        discard setFocus(state.hEdit)
      return 0

  of WM_INDEX_UPDATED:
    # Triggered by real-time USN monitor thread
    let textLen = getWindowTextLengthW(state.hEdit)
    var wBuf = newSeq[uint16](textLen + 1)
    let pW = cast[WideCString](addr wBuf[0])
    discard getWindowTextW(state.hEdit, pW, textLen + 1)
    let query = $pW
    state.executeSearch(query)
    return 0

  of WM_CLOSE:
    if not state.isExiting:
      # Minimize to tray on close
      discard showWindow(hWnd, SW_HIDE)
      return 0
    else:
      discard destroyWindow(hWnd)
      return 0

  of WM_DESTROY:
    discard unregisterHotKey(hWnd, HOTKEY_ID_MAIN)
    discard state.tray.removeTrayIcon()
    postQuitMessage(0)
    return 0

  else:
    return defWindowProcW(hWnd, uMsg, wParam, lParam)

  return 0

proc createMainWindow*(
  hInstance: HINSTANCE = nil,
  cfg: Config = defaultConfig(),
  searchCb: SearchCallback = nil,
  width: int32 = 820,
  height: int32 = 600
): ptr AppState =
  let state = create(AppState)
  state.config = cfg
  state.searchCallback = searchCb
  state.isExiting = false

  let className = "EverythingNimMainWindow"
  let wClassName = newWideCString(className)
  let wTitle = newWideCString("Everything-Nim")

  var wc: WNDCLASSEXW
  wc.cbSize = uint32(sizeof(WNDCLASSEXW))
  wc.style = 0
  wc.lpfnWndProc = wndProc
  wc.cbClsExtra = 0
  wc.cbWndExtra = 0
  wc.hInstance = hInstance
  wc.hIcon = loadIconW(nil, IDI_APPLICATION)
  wc.hCursor = loadCursorW(nil, IDC_ARROW)
  wc.hbrBackground = cast[HBRUSH](COLOR_WINDOW + 1)
  wc.lpszMenuName = nil
  wc.lpszClassName = wClassName
  wc.hIconSm = loadIconW(nil, IDI_APPLICATION)

  discard registerClassExW(addr wc)

  let hWnd = createWindowExW(
    WS_EX_APPWINDOW,
    wClassName,
    wTitle,
    WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN,
    CW_USEDEFAULT, CW_USEDEFAULT,
    width, height,
    nil,
    nil,
    hInstance,
    cast[pointer](state)
  )

  if hWnd.isNil:
    `=destroy`(state[])
    dealloc(state)
    return nil

  state.hWnd = hWnd
  state

proc runMessageLoop*(state: ptr AppState): int32 =
  if state.isNil or state.hWnd.isNil:
    return -1

  discard showWindow(state.hWnd, SW_SHOWNORMAL)
  discard updateWindow(state.hWnd)
  discard setForegroundWindow(state.hWnd)
  discard setFocus(state.hEdit)
  discard sendMessageW(state.hEdit, EM_SETSEL, 0, -1)
  logGui("runMessageLoop started, window shown, focus set")

  var msg: MSG
  while getMessageW(addr msg, nil, 0, 0) > 0:
    if msg.message == WM_KEYDOWN:
      if msg.wParam == WPARAM(VK_RETURN):
        let sel = sendMessageW(state.hListView, LVM_GETNEXTITEM, cast[WPARAM](-1), cast[LPARAM](LVNI_SELECTED))
        let targetRow = if sel >= 0 and sel < state.model.items.len: int(sel) elif state.model.items.len > 0: 0 else: -1
        if targetRow >= 0 and targetRow < state.model.items.len:
          let wPath = newWideCString(state.model.items[targetRow].path)
          let wOp = newWideCString("open")
          discard shellExecuteW(state.hWnd, wOp, wPath, nil, nil, SW_SHOWNORMAL)
        continue
      elif msg.wParam == WPARAM(VK_ESCAPE):
        discard showWindow(state.hWnd, SW_HIDE)
        continue
    discard translateMessage(addr msg)
    discard dispatchMessageW(addr msg)

  let exitCode = int32(msg.wParam)
  `=destroy`(state[])
  dealloc(state)
  exitCode
