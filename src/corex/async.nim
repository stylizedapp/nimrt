## corex/async — High-Performance Asynchronous I/O & Work-Stealing Reactor
##
## Integrates Windows I/O Completion Ports (IOCP) with the corex Work-Stealing
## ThreadPool for zero-overhead, non-blocking asynchronous file operations:
##
## - `AsyncReactor`: Dedicated background polling thread calling `GetQueuedCompletionStatusEx`
##   to dequeue up to 64 completions in a single kernel transition, dispatching completion
##   continuations directly into the `ThreadPool` injection queue.
## - `AsyncFile`: RAII handle for asynchronous file I/O operations (`asyncRead`, `asyncWrite`).
## - `OverlappedPool`: Dmitry Vyukov MPMC lock-free reusable pool of `OverlappedCtx` objects,
##   guaranteeing zero heap allocations on the hot completion path.
## - Zero exceptions: All APIs return `Result[T, int32]` and invoke `raises: []` callbacks.

import std/widestrs
import std/atomics
import ./result
import ./memory
import ./allocators
import ./concurrency

when defined(windows):
  import ./platform/windows/win32_iocp
  export win32_iocp.HANDLE, win32_iocp.INVALID_HANDLE_VALUE, win32_iocp.OVERLAPPED,
         win32_iocp.OVERLAPPED_ENTRY, win32_iocp.OverlappedCallback, win32_iocp.OverlappedCtx,
         win32_iocp.setOffset, win32_iocp.getOffset, win32_iocp.reset,
         win32_iocp.toOverlapped, win32_iocp.fromOverlapped

  # Win32 File Constants
  const
    GENERIC_READ* = 0x80000000'u32
    GENERIC_WRITE* = 0x40000000'u32
    FILE_SHARE_READ* = 0x00000001'u32
    FILE_SHARE_WRITE* = 0x00000002'u32
    FILE_SHARE_DELETE* = 0x00000004'u32
    CREATE_NEW* = 1'u32
    CREATE_ALWAYS* = 2'u32
    OPEN_EXISTING* = 3'u32
    OPEN_ALWAYS* = 4'u32
    TRUNCATE_EXISTING* = 5'u32
    FILE_ATTRIBUTE_NORMAL* = 0x00000080'u32
    FILE_FLAG_OVERLAPPED* = 0x40000000'u32

    ERROR_NOT_ENOUGH_MEMORY*: int32 = 8

    DefaultPoolCapacity* = 1024
    ReactorBatchSize* = 64
    ShutdownSentinelKey*: uint = 0xDEADBEEF_CAFE_0001'u

  proc winCreateFileW(
    lpFileName: WideCString,
    dwDesiredAccess: uint32,
    dwShareMode: uint32,
    lpSecurityAttributes: pointer,
    dwCreationDisposition: uint32,
    dwFlagsAndAttributes: uint32,
    hTemplateFile: HANDLE
  ): HANDLE {.importc: "CreateFileW", header: "<windows.h>", stdcall.}

  proc winReadFile(
    hFile: HANDLE,
    lpBuffer: pointer,
    nNumberOfBytesToRead: uint32,
    lpNumberOfBytesRead: ptr uint32,
    lpOverlapped: ptr OVERLAPPED
  ): BOOL {.importc: "ReadFile", header: "<windows.h>", stdcall.}

  proc winWriteFile(
    hFile: HANDLE,
    lpBuffer: pointer,
    nNumberOfBytesToWrite: uint32,
    lpNumberOfBytesWritten: ptr uint32,
    lpOverlapped: ptr OVERLAPPED
  ): BOOL {.importc: "WriteFile", header: "<windows.h>", stdcall.}

  # =============================================================================
  # 1. OverlappedPool (Lock-Free MPMC Reusable Context Pool)
  # =============================================================================

  type
    OverlappedPool* = object
      queue: MpmcQueue[ptr OverlappedCtx, 4096]
      storage: ptr UncheckedArray[OverlappedCtx]
      capacity: int
      allocator: Allocator

  proc `=copy`*(dest: var OverlappedPool, src: OverlappedPool) {.
    error: "OverlappedPool cannot be copied; pass by pointer or var reference".}

  proc initOverlappedPool*(
    capacity: int = DefaultPoolCapacity,
    allocator: Allocator = Allocator()
  ): OverlappedPool {.raises: [].} =
    let cap = min(max(capacity, 16), 4096)
    result.queue = initMpmcQueue[ptr OverlappedCtx, 4096]()
    result.capacity = cap
    result.allocator = allocator
    if allocator.allocFn != nil:
      let raw = allocator.allocFn(allocator.ctx, sizeof(OverlappedCtx) * cap, alignof(OverlappedCtx))
      result.storage = cast[ptr UncheckedArray[OverlappedCtx]](raw)
    else:
      result.storage = cast[ptr UncheckedArray[OverlappedCtx]](allocShared0(sizeof(OverlappedCtx) * cap))

    if result.storage != nil:
      zeroMem(result.storage, sizeof(OverlappedCtx) * cap)
      for i in 0 ..< cap:
        let ctx = addr result.storage[i]
        discard result.queue.push(ctx)

  proc isPreallocated(pool: ptr OverlappedPool, ctx: ptr OverlappedCtx): bool {.inline, raises: [].} =
    if pool.isNil or pool.storage.isNil or ctx.isNil: return false
    let base = cast[uint](pool.storage)
    let p = cast[uint](ctx)
    let endPtr = base + uint(sizeof(OverlappedCtx) * pool.capacity)
    p >= base and p < endPtr

  proc acquire*(pool: ptr OverlappedPool): ptr OverlappedCtx {.raises: [].} =
    ## Acquires an OverlappedCtx from the pool. Lock-free, zero heap allocation in steady state.
    if pool.isNil:
      let raw = allocShared0(sizeof(OverlappedCtx))
      result = cast[ptr OverlappedCtx](raw)
      result.pool = nil
      result.autoRecycle = false
      return result

    var ctx: ptr OverlappedCtx
    if pool.queue.pop(ctx):
      ctx.pool = pool
      ctx.autoRecycle = true
      return ctx

    # Burst fallback if pool temporarily exhausted
    if pool.allocator.allocFn != nil:
      let raw = pool.allocator.allocFn(pool.allocator.ctx, sizeof(OverlappedCtx), alignof(OverlappedCtx))
      result = cast[ptr OverlappedCtx](raw)
    else:
      result = cast[ptr OverlappedCtx](allocShared0(sizeof(OverlappedCtx)))
    if result != nil:
      zeroMem(result, sizeof(OverlappedCtx))
      result.pool = pool
      result.autoRecycle = true

  proc acquire*(pool: var OverlappedPool): ptr OverlappedCtx {.inline, raises: [].} =
    acquire(addr pool)

  proc recycle*(pool: ptr OverlappedPool, ctx: ptr OverlappedCtx) {.raises: [].} =
    ## Returns an OverlappedCtx back to the pool.
    if pool.isNil or ctx.isNil: return
    ctx.reset()
    ctx.pool = pool
    if not pool.queue.push(ctx):
      # Queue full; if dynamic fallback node, free it
      if not pool.isPreallocated(ctx):
        if pool.allocator.freeFn != nil:
          pool.allocator.freeFn(pool.allocator.ctx, ctx, sizeof(OverlappedCtx))
        else:
          deallocShared(ctx)

  proc recycle*(pool: var OverlappedPool, ctx: ptr OverlappedCtx) {.inline, raises: [].} =
    recycle(addr pool, ctx)

  proc destroy*(pool: var OverlappedPool) {.raises: [].} =
    ## Drains dynamic nodes and releases preallocated storage.
    var ctx: ptr OverlappedCtx
    while pool.queue.pop(ctx):
      if not (addr pool).isPreallocated(ctx):
        if pool.allocator.freeFn != nil:
          pool.allocator.freeFn(pool.allocator.ctx, ctx, sizeof(OverlappedCtx))
        else:
          deallocShared(ctx)

    if pool.storage != nil:
      if pool.allocator.freeFn != nil:
        pool.allocator.freeFn(pool.allocator.ctx, pool.storage, sizeof(OverlappedCtx) * pool.capacity)
      else:
        deallocShared(pool.storage)
      pool.storage = nil
      pool.capacity = 0

  # =============================================================================
  # 2. AsyncReactor (Dedicated IOCP Background Polling Thread)
  # =============================================================================

  type
    AsyncReactor* = object
      iocpHandle*: HANDLE
      pool*: ptr ThreadPool
      workerThread: Thread[ptr AsyncReactor]
      running*: Atomic[bool]
      started*: Atomic[bool]
      overlappedPool*: OverlappedPool
      allocator*: Allocator
      completedOps*: Atomic[uint64]
      failedOps*: Atomic[uint64]

  proc `=copy`*(dest: var AsyncReactor, src: AsyncReactor) {.
    error: "AsyncReactor cannot be copied; pass by pointer or var reference".}

  proc stop*(reactor: var AsyncReactor) {.raises: [].}
  proc destroy*(reactor: var AsyncReactor) {.raises: [].}

  proc `=destroy`*(reactor: var AsyncReactor) =
    destroy(reactor)

  proc dispatchCompletionJob(arg: pointer) {.nimcall, gcsafe, raises: [].} =
    ## Invoked on a ThreadPool worker thread to execute the callback and recycle the context.
    let ctx = cast[ptr OverlappedCtx](arg)
    if ctx != nil:
      let cb = ctx.callback
      let bytes = ctx.bytesTransferred
      let errCode = ctx.errorCode
      let udata = ctx.userData
      let poolPtr = cast[ptr OverlappedPool](ctx.pool)
      let autoRecycle = ctx.autoRecycle

      if cb != nil:
        cb(bytes, errCode, udata)

      if autoRecycle and poolPtr != nil:
        poolPtr.recycle(ctx)

  proc reactorWorkerProc(arg: ptr AsyncReactor) {.thread.} =
    let reactor = arg
    var entries: array[ReactorBatchSize, OVERLAPPED_ENTRY]

    while reactor.running.load(moAcquire):
      var removed: uint32 = 0
      let okVal = winGetQueuedCompletionStatusEx(
        reactor.iocpHandle,
        cast[ptr OVERLAPPED_ENTRY](addr entries[0]),
        uint32(ReactorBatchSize),
        addr removed,
        50'u32, # 50 ms timeout for clean responsive shutdown checks
        0'i32
      )

      if okVal != 0:
        for i in 0 ..< int(removed):
          let entry = addr entries[i]
          let completionKey = entry.lpCompletionKey
          let pOv = entry.lpOverlapped

          # Shutdown sentinel wakeup
          if completionKey == ShutdownSentinelKey or pOv == nil:
            continue

          let ctx = cast[ptr OverlappedCtx](pOv)
          ctx.bytesTransferred = entry.dwNumberOfBytesTransferred
          if entry.Internal == 0:
            ctx.errorCode = 0
          else:
            ctx.errorCode = cast[int32](rtlNtStatusToDosError(cast[int32](entry.Internal)))

          if ctx.errorCode == 0:
            reactor.completedOps.atomicInc(1)
          else:
            reactor.failedOps.atomicInc(1)

          # Dispatch directly to WorkStealing ThreadPool injection queue!
          if reactor.pool != nil:
            let job = Job(fn: dispatchCompletionJob, arg: ctx, cleanup: nil)
            reactor.pool.pushInjection(job)
          else:
            # Synchronous fallback if no ThreadPool is linked
            dispatchCompletionJob(ctx)
      else:
        let errCode = int32(winGetLastError())
        if errCode == WAIT_TIMEOUT:
          continue
        elif not reactor.running.load(moAcquire):
          break

  proc initAsyncReactor*(
    reactor: var AsyncReactor,
    pool: ptr ThreadPool,
    poolCapacity: int = DefaultPoolCapacity,
    allocator: Allocator = Allocator()
  ): Result[void, int32] {.raises: [].} =
    ## Initializes an existing AsyncReactor in-place and starts the I/O polling thread.
    let iocpRes = createCompletionPort(0)
    if not iocpRes.isOk:
      return err[void, int32](iocpRes.errVal)

    reactor.iocpHandle = iocpRes.val
    reactor.pool = pool
    reactor.overlappedPool = initOverlappedPool(poolCapacity, allocator)
    reactor.allocator = allocator
    reactor.running.store(true, moRelaxed)
    reactor.started.store(true, moRelaxed)
    reactor.completedOps.store(0'u64, moRelaxed)
    reactor.failedOps.store(0'u64, moRelaxed)

    try:
      createThread(reactor.workerThread, reactorWorkerProc, addr reactor)
    except CatchableError, Defect:
      reactor.started.store(false, moRelaxed)
      reactor.running.store(false, moRelaxed)
      discard winCloseHandle(reactor.iocpHandle)
      reactor.iocpHandle = nil
      return err[void, int32](ERROR_NOT_ENOUGH_MEMORY)

    ok[void, int32]()

  proc newAsyncReactor*(
    pool: ptr ThreadPool,
    poolCapacity: int = DefaultPoolCapacity,
    allocator: Allocator = Allocator()
  ): Result[ptr AsyncReactor, int32] {.raises: [].} =
    ## Allocates and starts a new AsyncReactor on the shared heap.
    let raw = if allocator.allocFn != nil:
      allocator.allocFn(allocator.ctx, sizeof(AsyncReactor), alignof(AsyncReactor))
    else:
      allocShared0(sizeof(AsyncReactor))
    if raw.isNil:
      return err[ptr AsyncReactor, int32](ERROR_NOT_ENOUGH_MEMORY)

    let p = cast[ptr AsyncReactor](raw)
    let iocpRes = createCompletionPort(0)
    if not iocpRes.isOk:
      if allocator.freeFn != nil: allocator.freeFn(allocator.ctx, raw, sizeof(AsyncReactor))
      else: deallocShared(raw)
      return err[ptr AsyncReactor, int32](iocpRes.errVal)

    p.iocpHandle = iocpRes.val
    p.pool = pool
    p.overlappedPool = initOverlappedPool(poolCapacity, allocator)
    p.allocator = allocator
    p.running.store(true, moRelaxed)
    p.started.store(true, moRelaxed)
    p.completedOps.store(0'u64, moRelaxed)
    p.failedOps.store(0'u64, moRelaxed)

    try:
      createThread(p.workerThread, reactorWorkerProc, p)
    except CatchableError, Defect:
      p.started.store(false, moRelaxed)
      p.running.store(false, moRelaxed)
      discard winCloseHandle(p.iocpHandle)
      p.iocpHandle = nil
      if allocator.freeFn != nil: allocator.freeFn(allocator.ctx, raw, sizeof(AsyncReactor))
      else: deallocShared(raw)
      return err[ptr AsyncReactor, int32](ERROR_NOT_ENOUGH_MEMORY)

    ok[ptr AsyncReactor, int32](p)

  proc stop*(reactor: var AsyncReactor) {.raises: [].} =
    ## Stops the reactor polling loop and waits for the thread to exit.
    if reactor.running.exchange(false, moAcqRel):
      if reactor.iocpHandle != nil and reactor.iocpHandle != INVALID_HANDLE_VALUE:
        discard winPostQueuedCompletionStatus(reactor.iocpHandle, 0, ShutdownSentinelKey, nil)
      if reactor.started.load(moAcquire):
        joinThread(reactor.workerThread)
        reactor.started.store(false, moRelease)

  proc stop*(reactor: ptr AsyncReactor) {.inline, raises: [].} =
    if reactor != nil: stop(reactor[])

  proc destroy*(reactor: var AsyncReactor) {.raises: [].} =
    ## Stops the reactor and cleans up all OS and memory resources.
    reactor.stop()
    if reactor.iocpHandle != nil and reactor.iocpHandle != INVALID_HANDLE_VALUE:
      discard winCloseHandle(reactor.iocpHandle)
      reactor.iocpHandle = nil
    destroy(reactor.overlappedPool)

  proc destroy*(reactor: ptr AsyncReactor) {.raises: [].} =
    ## Stops and deallocates a heap-allocated AsyncReactor.
    if reactor != nil:
      let alloc = reactor.allocator
      destroy(reactor[])
      if alloc.freeFn != nil:
        alloc.freeFn(alloc.ctx, reactor, sizeof(AsyncReactor))
      else:
        deallocShared(reactor)

  # =============================================================================
  # 3. Global Default AsyncReactor Facade
  # =============================================================================

  var gDefaultReactor: Atomic[pointer]
  var gDefaultReactorLock: SysLock = initSysLock()

  proc getDefaultReactor*(pool: ptr ThreadPool = nil): ptr AsyncReactor {.raises: [].} =
    ## Returns the process-wide shared default AsyncReactor instance, initialized lazily.
    var r = cast[ptr AsyncReactor](gDefaultReactor.load(moAcquire))
    if r == nil:
      acquire(gDefaultReactorLock)
      r = cast[ptr AsyncReactor](gDefaultReactor.load(moAcquire))
      if r == nil:
        var tp = pool
        if tp == nil:
          try:
            tp = getDefaultPool()
          except CatchableError, Defect:
            tp = nil
        let res = newAsyncReactor(tp)
        if res.isOk:
          r = res.val
          gDefaultReactor.store(cast[pointer](r), moRelease)
      release(gDefaultReactorLock)
    r

  proc shutdownAsyncReactor*() {.raises: [].} =
    ## Gracefully shuts down and frees the process-wide default AsyncReactor.
    if gDefaultReactor.load(moAcquire) != nil:
      acquire(gDefaultReactorLock)
      let p = gDefaultReactor.load(moAcquire)
      if p != nil:
        gDefaultReactor.store(nil, moRelease)
        destroy(cast[ptr AsyncReactor](p))
      release(gDefaultReactorLock)

  # =============================================================================
  # 4. AsyncFile (RAII Asynchronous File Descriptor)
  # =============================================================================

  type
    AsyncFile* = object
      handle*: HANDLE
      reactor*: ptr AsyncReactor
      ownsHandle*: bool

  proc `=copy`*(dest: var AsyncFile, src: AsyncFile) {.
    error: "AsyncFile cannot be copied; pass by pointer or var reference".}

  proc close*(file: var AsyncFile): Result[void, int32] {.raises: [].}

  proc `=destroy`*(file: var AsyncFile) =
    discard file.close()

  proc initAsyncFile*(
    reactor: ptr AsyncReactor,
    handle: HANDLE,
    ownsHandle: bool = false
  ): Result[AsyncFile, int32] {.raises: [].} =
    ## Wraps an existing OS handle opened with FILE_FLAG_OVERLAPPED and associates with reactor.
    if reactor.isNil or handle.isNil or handle == INVALID_HANDLE_VALUE:
      return err[AsyncFile, int32](ERROR_INVALID_HANDLE)

    let assocRes = associateWithCompletionPort(reactor.iocpHandle, handle, 0)
    if not assocRes.isOk:
      return err[AsyncFile, int32](assocRes.errVal)

    ok[AsyncFile, int32](AsyncFile(
      handle: handle,
      reactor: reactor,
      ownsHandle: ownsHandle
    ))

  proc openAsyncFile*(
    reactor: ptr AsyncReactor,
    path: string,
    writeAccess: bool = false,
    createAlways: bool = false
  ): Result[AsyncFile, int32] {.raises: [].} =
    ## Opens a file for asynchronous I/O with FILE_FLAG_OVERLAPPED and associates with reactor.
    if reactor.isNil:
      return err[AsyncFile, int32](ERROR_INVALID_HANDLE)

    let desiredAccess = if writeAccess: (GENERIC_READ or GENERIC_WRITE) else: GENERIC_READ
    let creation = if createAlways: CREATE_ALWAYS else: OPEN_EXISTING
    let flags = FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OVERLAPPED

    var wpath = newWideCString(path)
    let h = winCreateFileW(
      wpath,
      desiredAccess,
      FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil,
      creation,
      flags,
      nil
    )

    if h.isNil or h == INVALID_HANDLE_VALUE:
      return err[AsyncFile, int32](int32(winGetLastError()))

    let initRes = initAsyncFile(reactor, h, ownsHandle = true)
    if not initRes.isOk:
      discard closeHandle(h)
      return initRes
    initRes

  proc openAsyncFile*(
    path: string,
    writeAccess: bool = false,
    createAlways: bool = false
  ): Result[AsyncFile, int32] {.inline, raises: [].} =
    ## Opens a file for asynchronous I/O associated with the default AsyncReactor.
    openAsyncFile(getDefaultReactor(), path, writeAccess, createAlways)

  proc close*(file: var AsyncFile): Result[void, int32] {.raises: [].} =
    ## Closes the file handle if owned.
    if file.ownsHandle and file.handle != nil and file.handle != INVALID_HANDLE_VALUE:
      let h = file.handle
      file.handle = INVALID_HANDLE_VALUE
      return closeHandle(h)
    file.handle = INVALID_HANDLE_VALUE
    ok[void, int32]()

  # =============================================================================
  # 5. Non-Blocking asyncRead and asyncWrite Operations
  # =============================================================================

  proc asyncRead*(
    reactor: ptr AsyncReactor,
    handle: HANDLE,
    offset: int64,
    buf: ByteSpan,
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.raises: [].} =
    ## Submits a non-blocking asynchronous read request at `offset` into `buf`.
    ## Zero allocations on hot path via reactor.overlappedPool or custom `ctx`.
    if reactor.isNil or handle.isNil or handle == INVALID_HANDLE_VALUE:
      return err[void, int32](ERROR_INVALID_HANDLE)

    var opCtx = ctx
    var shouldRecycleOnFail = false
    if opCtx.isNil:
      opCtx = reactor.overlappedPool.acquire()
      opCtx.autoRecycle = true
      shouldRecycleOnFail = true
    else:
      opCtx.autoRecycle = false
      shouldRecycleOnFail = false

    opCtx.reset()
    opCtx.setOffset(offset)
    opCtx.callback = callback
    opCtx.userData = userData

    var bytesRead: uint32 = 0
    let okVal = winReadFile(
      handle,
      if buf.len > 0: cast[pointer](buf.data) else: nil,
      uint32(buf.len),
      addr bytesRead,
      addr opCtx.overlapped
    )

    if okVal == 0:
      let errCode = int32(winGetLastError())
      if errCode != ERROR_IO_PENDING:
        if shouldRecycleOnFail:
          reactor.overlappedPool.recycle(opCtx)
        return err[void, int32](errCode)

    ok[void, int32]()

  proc asyncRead*(
    file: var AsyncFile,
    offset: int64,
    buf: ByteSpan,
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.inline, raises: [].} =
    asyncRead(file.reactor, file.handle, offset, buf, callback, userData, ctx)

  proc asyncRead*(
    file: ptr AsyncFile,
    offset: int64,
    buf: ByteSpan,
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.inline, raises: [].} =
    if file.isNil: err[void, int32](ERROR_INVALID_HANDLE)
    else: asyncRead(file.reactor, file.handle, offset, buf, callback, userData, ctx)

  proc asyncRead*(
    handle: HANDLE,
    offset: int64,
    buf: ByteSpan,
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.inline, raises: [].} =
    asyncRead(getDefaultReactor(), handle, offset, buf, callback, userData, ctx)

  proc asyncRead*(
    file: var AsyncFile,
    offset: int64,
    buf: openArray[byte],
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.inline, raises: [].} =
    asyncRead(file.reactor, file.handle, offset, span(buf), callback, userData, ctx)

  proc asyncWrite*(
    reactor: ptr AsyncReactor,
    handle: HANDLE,
    offset: int64,
    buf: ByteSpan,
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.raises: [].} =
    ## Submits a non-blocking asynchronous write request at `offset` from `buf`.
    ## Zero allocations on hot path via reactor.overlappedPool or custom `ctx`.
    if reactor.isNil or handle.isNil or handle == INVALID_HANDLE_VALUE:
      return err[void, int32](ERROR_INVALID_HANDLE)

    var opCtx = ctx
    var shouldRecycleOnFail = false
    if opCtx.isNil:
      opCtx = reactor.overlappedPool.acquire()
      opCtx.autoRecycle = true
      shouldRecycleOnFail = true
    else:
      opCtx.autoRecycle = false
      shouldRecycleOnFail = false

    opCtx.reset()
    opCtx.setOffset(offset)
    opCtx.callback = callback
    opCtx.userData = userData

    var bytesWritten: uint32 = 0
    let okVal = winWriteFile(
      handle,
      if buf.len > 0: cast[pointer](buf.data) else: nil,
      uint32(buf.len),
      addr bytesWritten,
      addr opCtx.overlapped
    )

    if okVal == 0:
      let errCode = int32(winGetLastError())
      if errCode != ERROR_IO_PENDING:
        if shouldRecycleOnFail:
          reactor.overlappedPool.recycle(opCtx)
        return err[void, int32](errCode)

    ok[void, int32]()

  proc asyncWrite*(
    file: var AsyncFile,
    offset: int64,
    buf: ByteSpan,
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.inline, raises: [].} =
    asyncWrite(file.reactor, file.handle, offset, buf, callback, userData, ctx)

  proc asyncWrite*(
    file: ptr AsyncFile,
    offset: int64,
    buf: ByteSpan,
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.inline, raises: [].} =
    if file.isNil: err[void, int32](ERROR_INVALID_HANDLE)
    else: asyncWrite(file.reactor, file.handle, offset, buf, callback, userData, ctx)

  proc asyncWrite*(
    handle: HANDLE,
    offset: int64,
    buf: ByteSpan,
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.inline, raises: [].} =
    asyncWrite(getDefaultReactor(), handle, offset, buf, callback, userData, ctx)

  proc asyncWrite*(
    file: var AsyncFile,
    offset: int64,
    buf: openArray[byte],
    callback: OverlappedCallback,
    userData: pointer = nil,
    ctx: ptr OverlappedCtx = nil
  ): Result[void, int32] {.inline, raises: [].} =
    asyncWrite(file.reactor, file.handle, offset, span(buf), callback, userData, ctx)

else:
  # Fallback stub for non-Windows platforms
  type
    HANDLE* = pointer
    OverlappedCallback* = proc(bytesTransferred: uint32, err: int32, userData: pointer) {.gcsafe, raises: [].}
    AsyncReactor* = object
    AsyncFile* = object
