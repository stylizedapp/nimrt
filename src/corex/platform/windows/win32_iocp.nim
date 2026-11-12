## corex/platform/windows/win32_iocp — Native Windows IOCP Primitives
##
## Provides high-performance, zero-overhead Windows I/O Completion Port (IOCP) bindings
## and data structures engineered for zero-allocation asynchronous I/O:
##
## - Native Win32 API Bindings:
##   - `CreateIoCompletionPort`: Create completion ports or associate existing handles.
##   - `CloseHandle`: Release completion port handles.
##   - `GetQueuedCompletionStatusEx`: Batch dequeuing of up to 32/64 completion packets in a single kernel transition.
##   - `PostQueuedCompletionStatus`: High-speed cross-thread signaling and wakeups.
## - `OverlappedCtx`: Zero-allocation structure extending Win32 `OVERLAPPED` with completion callback.
## - `Result[T, int32]` error handling without exceptions (raises: []).

import ../../result

# =============================================================================
# 1. Win32 Types, Enums & Constants
# =============================================================================

type
  HANDLE* = pointer
  BOOL* = int32
  DWORD* = uint32
  ULONG_PTR* = uint

const
  INVALID_HANDLE_VALUE* = cast[HANDLE](-1)
  INFINITE*: uint32 = 0xFFFFFFFF'u32

  # Win32 Error Codes
  ERROR_SUCCESS*: int32 = 0
  WAIT_TIMEOUT*: int32 = 258
  ERROR_HANDLE_EOF*: int32 = 38
  ERROR_OPERATION_ABORTED*: int32 = 995
  ERROR_IO_PENDING*: int32 = 997
  ERROR_INVALID_HANDLE*: int32 = 6

type
  OVERLAPPED* {.importc: "OVERLAPPED", header: "<windows.h>", completeStruct, byref.} = object
    Internal*: uint
    InternalHigh*: uint
    Offset*: uint32
    OffsetHigh*: uint32
    hEvent*: pointer

  OVERLAPPED_ENTRY* {.importc: "OVERLAPPED_ENTRY", header: "<windows.h>", completeStruct.} = object
    lpCompletionKey*: uint
    lpOverlapped*: ptr OVERLAPPED
    Internal*: uint
    dwNumberOfBytesTransferred*: uint32

  OverlappedCallback* = proc(bytesTransferred: uint32, err: int32, userData: pointer) {.gcsafe, raises: [].}

  OverlappedCtx* = object
    ## Zero-allocation context extending OVERLAPPED.
    ## `overlapped` MUST be the first field at offset 0 so that
    ## `cast[ptr OverlappedCtx](pOverlapped)` and `cast[ptr OVERLAPPED](addr ctx)`
    ## are identical in memory.
    overlapped*: OVERLAPPED
    callback*: OverlappedCallback
    userData*: pointer
    bytesTransferred*: uint32
    errorCode*: int32
    pool*: pointer
    next*: ptr OverlappedCtx
    autoRecycle*: bool

# Compile-time sanity check: overlapped must be at offset 0
static:
  assert offsetof(OverlappedCtx, overlapped) == 0, "OverlappedCtx.overlapped must be at offset 0"

# =============================================================================
# 2. Raw Win32 & NT C Bindings
# =============================================================================

proc winCreateIoCompletionPort*(
  fileHandle: HANDLE,
  existingCompletionPort: HANDLE,
  completionKey: uint,
  numberOfConcurrentThreads: uint32
): HANDLE {.importc: "CreateIoCompletionPort", header: "<windows.h>", stdcall.}

proc winCloseHandle*(hObject: HANDLE): BOOL {.
  importc: "CloseHandle", header: "<windows.h>", stdcall.}

proc winPostQueuedCompletionStatus*(
  completionPort: HANDLE,
  dwNumberOfBytesTransferred: uint32,
  dwCompletionKey: uint,
  lpOverlapped: ptr OVERLAPPED
): BOOL {.importc: "PostQueuedCompletionStatus", header: "<windows.h>", stdcall.}

proc winGetQueuedCompletionStatusEx*(
  completionPort: HANDLE,
  lpCompletionPortEntries: ptr OVERLAPPED_ENTRY,
  ulCount: uint32,
  ulNumEntriesRemoved: ptr uint32,
  dwMilliseconds: uint32,
  fAlertable: BOOL
): BOOL {.importc: "GetQueuedCompletionStatusEx", header: "<windows.h>", stdcall.}

proc winGetLastError*(): DWORD {.
  importc: "GetLastError", header: "<windows.h>", stdcall.}

proc winSetLastError*(dwErrCode: DWORD) {.
  importc: "SetLastError", header: "<windows.h>", stdcall.}

proc rtlNtStatusToDosError*(status: int32): uint32 {.
  importc: "RtlNtStatusToDosError", dynlib: "ntdll.dll", stdcall.}

# =============================================================================
# 3. OverlappedCtx Operations
# =============================================================================

proc setOffset*(ctx: var OverlappedCtx, offset: int64) {.inline, raises: [].} =
  ## Sets the 64-bit file offset in the inner OVERLAPPED structure.
  ctx.overlapped.Offset = uint32(offset and 0xFFFFFFFF'i64)
  ctx.overlapped.OffsetHigh = uint32((offset shr 32) and 0xFFFFFFFF'i64)

proc setOffset*(ctx: ptr OverlappedCtx, offset: int64) {.inline, raises: [].} =
  if ctx != nil: setOffset(ctx[], offset)

proc getOffset*(ctx: OverlappedCtx): int64 {.inline, raises: [].} =
  ## Returns the 64-bit file offset from the inner OVERLAPPED structure.
  int64(ctx.overlapped.Offset) or (int64(ctx.overlapped.OffsetHigh) shl 32)

proc getOffset*(ctx: ptr OverlappedCtx): int64 {.inline, raises: [].} =
  if ctx.isNil: 0'i64 else: getOffset(ctx[])

proc reset*(ctx: var OverlappedCtx) {.inline, raises: [].} =
  ## Clears the inner OVERLAPPED structure and resets status fields before reuse.
  zeroMem(addr ctx.overlapped, sizeof(OVERLAPPED))
  ctx.callback = nil
  ctx.userData = nil
  ctx.bytesTransferred = 0
  ctx.errorCode = 0
  ctx.next = nil
  ctx.autoRecycle = false

proc reset*(ctx: ptr OverlappedCtx) {.inline, raises: [].} =
  if ctx != nil: reset(ctx[])

proc toOverlapped*(ctx: ptr OverlappedCtx): ptr OVERLAPPED {.inline, raises: [].} =
  ## Returns the pointer to the inner OVERLAPPED structure.
  if ctx.isNil: nil else: addr ctx.overlapped

proc toOverlapped*(ctx: var OverlappedCtx): ptr OVERLAPPED {.inline, raises: [].} =
  ## Returns the pointer to the inner OVERLAPPED structure.
  addr ctx.overlapped

proc fromOverlapped*(ov: ptr OVERLAPPED): ptr OverlappedCtx {.inline, raises: [].} =
  ## Recovers the OverlappedCtx pointer from an OVERLAPPED pointer.
  cast[ptr OverlappedCtx](ov)

# =============================================================================
# 4. Idiomatic Zero-Overhead Result-Based Wrappers
# =============================================================================

proc createCompletionPort*(numberOfConcurrentThreads: uint32 = 0): Result[HANDLE, int32] {.raises: [].} =
  ## Creates a new standalone I/O completion port.
  let port = winCreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, numberOfConcurrentThreads)
  if port.isNil:
    return err[HANDLE, int32](int32(winGetLastError()))
  ok[HANDLE, int32](port)

proc associateWithCompletionPort*(
  port: HANDLE,
  fileHandle: HANDLE,
  completionKey: uint = 0
): Result[void, int32] {.raises: [].} =
  ## Associates an existing file or device handle with an I/O completion port.
  let res = winCreateIoCompletionPort(fileHandle, port, completionKey, 0)
  if res.isNil:
    return err[void, int32](int32(winGetLastError()))
  ok[void, int32]()

proc closeHandle*(handle: HANDLE): Result[void, int32] {.raises: [].} =
  ## Closes an open Win32 handle.
  if handle.isNil or handle == INVALID_HANDLE_VALUE:
    return ok[void, int32]()
  let okVal = winCloseHandle(handle)
  if okVal == 0:
    return err[void, int32](int32(winGetLastError()))
  ok[void, int32]()

proc postQueuedCompletionStatus*(
  port: HANDLE,
  bytesTransferred: uint32 = 0,
  completionKey: uint = 0,
  overlapped: ptr OVERLAPPED = nil
): Result[void, int32] {.raises: [].} =
  ## Posts an I/O completion packet directly to the completion port.
  let okVal = winPostQueuedCompletionStatus(port, bytesTransferred, completionKey, overlapped)
  if okVal == 0:
    return err[void, int32](int32(winGetLastError()))
  ok[void, int32]()

proc getQueuedCompletionStatusEx*(
  port: HANDLE,
  entries: ptr UncheckedArray[OVERLAPPED_ENTRY],
  count: uint32,
  numRemoved: var uint32,
  timeoutMs: uint32 = INFINITE,
  alertable: bool = false
): Result[void, int32] {.raises: [].} =
  ## Batch dequeues up to `count` completion entries in a single kernel transition.
  let okVal = winGetQueuedCompletionStatusEx(
    port,
    cast[ptr OVERLAPPED_ENTRY](entries),
    count,
    addr numRemoved,
    timeoutMs,
    if alertable: 1'i32 else: 0'i32
  )
  if okVal == 0:
    return err[void, int32](int32(winGetLastError()))
  ok[void, int32]()

proc pollCompletions*(
  port: HANDLE,
  entries: var openArray[OVERLAPPED_ENTRY],
  timeoutMs: uint32 = INFINITE
): Result[int, int32] {.raises: [].} =
  ## Convenience batch poller filling `entries`. Returns the count of removed entries.
  if entries.len <= 0:
    return ok[int, int32](0)
  var removed: uint32 = 0
  let okVal = winGetQueuedCompletionStatusEx(
    port,
    addr entries[0],
    uint32(entries.len),
    addr removed,
    timeoutMs,
    0'i32
  )
  if okVal == 0:
    let errCode = int32(winGetLastError())
    if errCode == WAIT_TIMEOUT:
      return ok[int, int32](0)
    return err[int, int32](errCode)
  ok[int, int32](int(removed))
