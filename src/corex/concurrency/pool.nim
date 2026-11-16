## corex/concurrency/pool — Work-Stealing Chase-Lev ThreadPool & Default Pool Singleton
##
## Implements `ThreadPool` with per-worker Chase-Lev deques, lock-free local submission,
## OS condition variable parking at 0% idle CPU, and `Result`-based error paths without
## catching `Defect`.
##
## Runtime singleton semantics:
## `getDefaultPool()` lazily creates an owned process-wide `ThreadPool` on first call
## (synchronized via zero-init `SpinLock` with no hidden OS lock constructor). Callers
## needing explicit pool ownership can create their own `ThreadPool` or register it via
## `setDefaultPool(pool, takeOwnership = false)` and call `shutdownThreadPool()` on exit.

import std/atomics
import std/sysatomics
import std/cpuinfo
import ./primitives
import ../workstealing
import ../result

export workstealing.WorkStealDeque, workstealing.JobDeque, workstealing.Job, workstealing.JobProc

type
  ConcurrencyError* = enum
    cePoolStopped
    ceThreadCreateFailed

  Task* = proc() {.gcsafe.}

  WorkerArg = object
    pool: ptr ThreadPool
    workerId: int

  TaskEnv = object
    task: Task
    pool: ptr ThreadPool
    ownerThread: uint64
    next: ptr TaskEnv

  ThreadPool* = object
    threads: seq[Thread[ptr WorkerArg]]
    workerArgs: ptr UncheckedArray[WorkerArg]
    deques: ptr UncheckedArray[ptr WorkStealDeque[Job]]
    queue: ptr UncheckedArray[Job]
    queueCap: int
    queueHead: int
    queueTail: int
    queueCount: Atomic[int]
    numWorkers: int
    lock: SysLock
    condWork: CondVar
    running: Atomic[bool]
    isShutDown: bool
    threadsStarted: Atomic[bool]
    sleepingWorkers: Atomic[int]
    retiredLock: SpinLock
    retiredTasks: ptr TaskEnv

proc `=copy`*(dest: var ThreadPool, src: ThreadPool) {.
  error: "ThreadPool cannot be copied; pass by pointer or var reference".}

proc `=destroy`*(pool: var ThreadPool) {.raises: [].}

# Thread-local worker context
var tWorkerPool {.threadvar.}: pointer
var tWorkerId {.threadvar.}: int
var tRngState {.threadvar.}: uint64
var gNextThreadId: Atomic[uint64]
var tThreadId {.threadvar.}: uint64

proc currentThreadToken(): uint64 {.inline.} =
  if tThreadId == 0'u64:
    tThreadId = atomics.fetchAdd(gNextThreadId, 1'u64, atomics.moRelaxed) + 1'u64
  tThreadId

proc currentWorkerId*(): int {.inline.} =
  ## Returns the 0-based worker thread ID if called within a ThreadPool worker, or -1 otherwise.
  tWorkerId

proc isWorkerOf*(pool: ptr ThreadPool): bool {.inline.} =
  tWorkerPool == cast[pointer](pool) and tWorkerId >= 0 and tWorkerId < pool.numWorkers

proc effectiveWorkerCount*(pool: var ThreadPool): int {.inline.} =
  if atomics.load(pool.threadsStarted, atomics.moAcquire) and pool.threads.len > 0:
    pool.threads.len
  elif pool.numWorkers > 0:
    pool.numWorkers
  else:
    max(1, countProcessors())

proc isRunning*(pool: var ThreadPool): bool {.inline.} =
  atomics.load(pool.running, atomics.moAcquire) and not pool.isShutDown

proc nextRand(maxVal: int): int {.inline.} =
  if maxVal <= 1: return 0
  if tRngState == 0:
    tRngState = uint64(tWorkerId + 1) * 0x9E3779B97F4A7C15'u64 + 1
  tRngState = tRngState xor (tRngState shl 13)
  tRngState = tRngState xor (tRngState shr 7)
  tRngState = tRngState xor (tRngState shl 17)
  return int(tRngState mod uint64(maxVal))

proc allLocalDequesEmpty(pool: ptr ThreadPool): bool {.inline.} =
  if pool.deques != nil:
    for i in 0 ..< pool.numWorkers:
      if pool.deques[i] != nil and not pool.deques[i].empty:
        return false
  return true

proc allQueuesEmpty(pool: ptr ThreadPool): bool {.inline.} =
  if atomics.load(pool.queueCount, atomics.moRelaxed) > 0:
    return false
  return pool.allLocalDequesEmpty()

proc popInjection*(pool: ptr ThreadPool, workerId: int, job: var Job): bool =
  if atomics.load(pool.queueCount, atomics.moRelaxed) == 0:
    return false

  acquire(pool.lock)
  let count = atomics.load(pool.queueCount, atomics.moRelaxed)
  if count > 0:
    job = pool.queue[pool.queueHead]
    pool.queue[pool.queueHead] = Job(fn: nil, arg: nil, cleanup: nil)
    pool.queueHead = (pool.queueHead + 1) mod pool.queueCap
    pool.queueCount.atomicDec(1)
    result = true

    if workerId >= 0 and workerId < pool.numWorkers and pool.deques != nil and pool.deques[workerId] != nil:
      let rem = atomics.load(pool.queueCount, atomics.moRelaxed)
      let batch = min(rem, 15)
      for _ in 0 ..< batch:
        var bJob = pool.queue[pool.queueHead]
        pool.queue[pool.queueHead] = Job(fn: nil, arg: nil, cleanup: nil)
        pool.queueHead = (pool.queueHead + 1) mod pool.queueCap
        pool.queueCount.atomicDec(1)
        pool.deques[workerId].push(bJob)

      if batch > 0 and atomics.load(pool.sleepingWorkers, atomics.moRelaxed) > 0:
        wakeOne(pool.condWork)

  release(pool.lock)

proc popInjection*(pool: var ThreadPool, workerId: int, job: var Job): bool {.inline.} =
  popInjection(addr pool, workerId, job)

proc stealWork*(pool: ptr ThreadPool, workerId: int, job: var Job): bool =
  let n = pool.numWorkers
  if n <= 1 or pool.deques == nil:
    return false
  let start = nextRand(n)
  for i in 0 ..< n:
    let victim = (start + i) mod n
    if victim != workerId and pool.deques[victim] != nil:
      if pool.deques[victim].steal(job):
        return true
  return false

proc stealWork*(pool: var ThreadPool, workerId: int, job: var Job): bool {.inline.} =
  stealWork(addr pool, workerId, job)

proc popLocalWork*(pool: ptr ThreadPool, job: var Job): bool {.inline.} =
  if tWorkerId >= 0 and tWorkerId < pool.numWorkers and pool.deques != nil and pool.deques[tWorkerId] != nil:
    return pool.deques[tWorkerId].pop(job)
  false

proc wakeAllWorkers*(pool: var ThreadPool) {.inline.} =
  if atomics.load(pool.sleepingWorkers, atomics.moRelaxed) > 0:
    wakeAll(pool.condWork)

proc workerProc(arg: ptr WorkerArg) {.thread.} =
  let pool = arg.pool
  let workerId = arg.workerId
  tWorkerPool = cast[pointer](pool)
  tWorkerId = workerId

  try:
    while true:
      var job: Job
      var found = false

      if pool.deques[workerId].pop(job):
        found = true
      if not found:
        found = pool.popInjection(workerId, job)
      if not found:
        found = pool.stealWork(workerId, job)

      if found:
        execute(job)
        continue

      if not atomics.load(pool.running, atomics.moAcquire):
        if pool.allQueuesEmpty():
          break

      var foundDuringSpin = false
      const MaxSpins = 32
      var spins = 0
      while spins < MaxSpins:
        for _ in 0 ..< 4:
          cpuRelax()
        inc(spins)

        if pool.deques[workerId].pop(job):
          foundDuringSpin = true
          break
        if pool.popInjection(workerId, job):
          foundDuringSpin = true
          break
        if (spins and 7) == 0:
          if pool.stealWork(workerId, job):
            foundDuringSpin = true
            break

      if foundDuringSpin:
        execute(job)
        continue

      acquire(pool.lock)
      if not atomics.load(pool.running, atomics.moAcquire):
        if pool.allQueuesEmpty():
          release(pool.lock)
          break

      if atomics.load(pool.queueCount, atomics.moRelaxed) > 0:
        job = pool.queue[pool.queueHead]
        pool.queue[pool.queueHead] = Job(fn: nil, arg: nil, cleanup: nil)
        pool.queueHead = (pool.queueHead + 1) mod pool.queueCap
        pool.queueCount.atomicDec(1)
        release(pool.lock)
        execute(job)
        continue

      if not pool.allLocalDequesEmpty():
        release(pool.lock)
        continue

      if not atomics.load(pool.running, atomics.moAcquire):
        release(pool.lock)
        break

      pool.sleepingWorkers.atomicInc(1)
      waitCondVar(pool.condWork, pool.lock)
      pool.sleepingWorkers.atomicDec(1)
      release(pool.lock)

  finally:
    tWorkerPool = nil
    tWorkerId = -1

proc tryEnsureWorkers*(pool: var ThreadPool): Result[void, ConcurrencyError] =
  if not atomics.load(pool.running, atomics.moAcquire) or pool.isShutDown:
    return err[void, ConcurrencyError](cePoolStopped)
  if not atomics.load(pool.threadsStarted, atomics.moAcquire):
    acquire(pool.lock)
    if not atomics.load(pool.threadsStarted, atomics.moRelaxed) and atomics.load(pool.running, atomics.moRelaxed) and not pool.isShutDown:
      let count = if pool.numWorkers > 0: pool.numWorkers else: max(1, countProcessors())
      pool.numWorkers = count

      pool.workerArgs = cast[ptr UncheckedArray[WorkerArg]](allocShared0(sizeof(WorkerArg) * count))
      pool.deques = cast[ptr UncheckedArray[ptr WorkStealDeque[Job]]](allocShared0(sizeof(ptr WorkStealDeque[Job]) * count))
      for i in 0 ..< count:
        pool.deques[i] = newWorkStealDeque[Job](64)
        pool.workerArgs[i].pool = addr pool
        pool.workerArgs[i].workerId = i

      pool.threads = newSeq[Thread[ptr WorkerArg]](count)
      var startedCount = 0
      var createFailed = false
      for i in 0 ..< count:
        try:
          createThread(pool.threads[i], workerProc, addr pool.workerArgs[i])
          inc(startedCount)
        except CatchableError:
          createFailed = true
          break

      if createFailed:
        atomics.store(pool.running, false, atomics.moRelease)
        wakeAll(pool.condWork)
        release(pool.lock)
        for i in 0 ..< startedCount:
          joinThread(pool.threads[i])
        pool.threads.setLen(0)
        return err[void, ConcurrencyError](ceThreadCreateFailed)

      atomics.store(pool.threadsStarted, true, atomics.moRelease)
    release(pool.lock)
  ok[void, ConcurrencyError]()

proc ensureWorkers(pool: var ThreadPool) =
  let res = pool.tryEnsureWorkers()
  if res.isErr:
    raiseAssert("ThreadPool failed to spawn worker threads: " & $res.error)

proc initThreadPoolFields(pool: var ThreadPool, numThreads: int) {.raises: [].} =
  let count = if numThreads > 0: numThreads else: max(1, countProcessors())
  const InitialCapacity = 2048
  pool.queueCap = InitialCapacity
  pool.queue = cast[ptr UncheckedArray[Job]](allocShared0(sizeof(Job) * InitialCapacity))
  pool.queueHead = 0
  pool.queueTail = 0
  atomics.store(pool.queueCount, 0, atomics.moRelaxed)
  pool.numWorkers = count
  initSysLock(pool.lock)
  initCondVar(pool.condWork)
  atomics.store(pool.running, true, atomics.moRelaxed)
  pool.isShutDown = false
  atomics.store(pool.threadsStarted, false, atomics.moRelaxed)
  atomics.store(pool.sleepingWorkers, 0, atomics.moRelaxed)
  initSpinLock(pool.retiredLock)
  pool.retiredTasks = nil

proc initThreadPool*(numThreads: int = 0): ThreadPool {.raises: [].} =
  ## Initializes a ThreadPool with the specified number of worker threads (default: CPU cores).
  initThreadPoolFields(result, numThreads)

proc initThreadPool*(pool: var ThreadPool, numThreads: int = 0) =
  ## Initializes an existing ThreadPool in-place and starts worker threads immediately.
  initThreadPoolFields(pool, numThreads)
  pool.ensureWorkers()

proc newThreadPool*(numThreads: int = 0): ptr ThreadPool {.raises: [].} =
  ## Allocates and initializes a ThreadPool on the shared heap (workers start lazily on first task).
  result = cast[ptr ThreadPool](allocShared0(sizeof(ThreadPool)))
  initThreadPoolFields(result[], numThreads)

proc tryPushInjection*(pool: var ThreadPool, job: Job): Result[void, ConcurrencyError] =
  ## Pushes a job to the global injection queue, returning Err(cePoolStopped) if shut down.
  let wRes = pool.tryEnsureWorkers()
  if wRes.isErr:
    if job.cleanup != nil and job.arg != nil:
      job.cleanup(job.arg)
    return wRes

  acquire(pool.lock)
  if not atomics.load(pool.running, atomics.moRelaxed) or pool.isShutDown:
    release(pool.lock)
    if job.cleanup != nil and job.arg != nil:
      job.cleanup(job.arg)
    return err[void, ConcurrencyError](cePoolStopped)

  if atomics.load(pool.queueCount, atomics.moRelaxed) == pool.queueCap:
    let oldCap = pool.queueCap
    let newCap = oldCap * 2
    let newQueue = cast[ptr UncheckedArray[Job]](allocShared0(sizeof(Job) * newCap))
    for i in 0 ..< pool.queueCap:
      newQueue[i] = pool.queue[(pool.queueHead + i) mod oldCap]
    deallocShared(pool.queue)
    pool.queue = newQueue
    pool.queueCap = newCap
    pool.queueHead = 0
    pool.queueTail = oldCap

  pool.queue[pool.queueTail] = job
  pool.queueTail = (pool.queueTail + 1) mod pool.queueCap
  pool.queueCount.atomicInc(1)

  wakeOne(pool.condWork)
  release(pool.lock)
  ok[void, ConcurrencyError]()

proc tryPushInjection*(pool: ptr ThreadPool, job: Job): Result[void, ConcurrencyError] {.inline.} =
  tryPushInjection(pool[], job)

proc pushInjection*(pool: var ThreadPool, job: Job) =
  let res = pool.tryPushInjection(job)
  if res.isErr:
    raiseAssert("Cannot submit job on stopped ThreadPool")

proc pushInjection*(pool: ptr ThreadPool, job: Job) {.inline.} =
  pushInjection(pool[], job)

proc trySubmitJob*(pool: var ThreadPool, job: Job): Result[void, ConcurrencyError] =
  let wRes = pool.tryEnsureWorkers()
  if wRes.isErr:
    if job.cleanup != nil and job.arg != nil:
      job.cleanup(job.arg)
    return wRes
  let poolPtr = cast[pointer](addr pool)
  if tWorkerPool == poolPtr and tWorkerId >= 0 and tWorkerId < pool.numWorkers:
    if not atomics.load(pool.running, atomics.moAcquire) or pool.isShutDown:
      if job.cleanup != nil and job.arg != nil:
        job.cleanup(job.arg)
      return err[void, ConcurrencyError](cePoolStopped)
    pool.deques[tWorkerId].push(job)
    if atomics.load(pool.sleepingWorkers, atomics.moRelaxed) > 0:
      wakeOne(pool.condWork)
    return ok[void, ConcurrencyError]()
  pool.tryPushInjection(job)

proc trySubmitJob*(pool: ptr ThreadPool, job: Job): Result[void, ConcurrencyError] {.inline.} =
  trySubmitJob(pool[], job)

proc submitJob*(pool: var ThreadPool, job: Job) =
  let res = pool.trySubmitJob(job)
  if res.isErr:
    raiseAssert("Cannot submit job on stopped ThreadPool")

proc submitJob*(pool: ptr ThreadPool, job: Job) {.inline.} =
  submitJob(pool[], job)

type
  ClosureRaw = object
    fn: pointer
    env: pointer

  TNimTypeV2 = object
    destructor: pointer
    size: int
    align: int16
    depth: int16
    display: ptr uint32
    traceImpl: pointer
    typeInfoV1: pointer
    flags: int

  RefHeader = object
    rc: int
    when defined(gcOrc):
      rootIdx: int
    when defined(nimArcDebug) or defined(nimArcIds):
      refId: int

proc sanitizeClosure(env: pointer) {.inline.} =
  when defined(gcOrc):
    if env != nil:
      let pDesc = cast[ptr ptr TNimTypeV2](env)[]
      if pDesc != nil and (pDesc.flags and 1) == 0:
        pDesc.flags = pDesc.flags or 1 # acyclicFlag
      let cell = cast[ptr RefHeader](cast[int](env) - sizeof(RefHeader))
      if cell.rootIdx > 0:
        GC_runOrc()

proc drainRetiredTasks(pool: var ThreadPool, onlyOwner: uint64) {.raises: [].} =
  var head: ptr TaskEnv
  withLock(pool.retiredLock):
    head = pool.retiredTasks
    pool.retiredTasks = nil
  if head == nil:
    return
  var keepHead: ptr TaskEnv = nil
  var keepTail: ptr TaskEnv = nil
  var cur = head
  while cur != nil:
    let nxt = cur.next
    cur.next = nil
    if onlyOwner == 0'u64 or cur.ownerThread == onlyOwner:
      reset(cur.task)
      deallocShared(cur)
    else:
      if keepHead == nil:
        keepHead = cur
      else:
        keepTail.next = cur
      keepTail = cur
    cur = nxt
  if keepHead != nil:
    withLock(pool.retiredLock):
      keepTail.next = pool.retiredTasks
      pool.retiredTasks = keepHead

proc runTaskEnv(p: pointer) {.nimcall, gcsafe.} =
  let env = cast[ptr TaskEnv](p)
  if env != nil and env.task != nil:
    env.task()

proc freeTaskEnv(p: pointer) {.nimcall, gcsafe.} =
  let env = cast[ptr TaskEnv](p)
  if env != nil:
    if env.ownerThread == 0'u64 or env.ownerThread == currentThreadToken():
      reset(env.task)
      deallocShared(env)
    else:
      let pool = env.pool
      withLock(pool.retiredLock):
        env.next = pool.retiredTasks
        pool.retiredTasks = env

proc trySpawn*(pool: var ThreadPool, task: proc() {.gcsafe.}): Result[void, ConcurrencyError] =
  ## Submits a task closure for asynchronous execution, returning Result on stopped/failed pool.
  let owner = currentThreadToken()
  pool.drainRetiredTasks(owner)
  let wRes = pool.tryEnsureWorkers()
  if wRes.isErr:
    return wRes
  let env = cast[ptr TaskEnv](allocShared0(sizeof(TaskEnv)))
  env.task = task
  env.pool = addr pool
  let raw = cast[ClosureRaw](task)
  if raw.env != nil:
    sanitizeClosure(raw.env)
    env.ownerThread = owner
  else:
    env.ownerThread = 0'u64
  let job = Job(fn: runTaskEnv, arg: env, cleanup: freeTaskEnv)
  pool.trySubmitJob(job)

proc trySpawn*(pool: ptr ThreadPool, task: proc() {.gcsafe.}): Result[void, ConcurrencyError] {.inline.} =
  trySpawn(pool[], task)

proc spawn*(pool: var ThreadPool, task: proc() {.gcsafe.}) =
  ## Submits a task closure for asynchronous execution in the thread pool.
  let res = pool.trySpawn(task)
  if res.isErr:
    raiseAssert("Cannot submit job on stopped ThreadPool")

proc spawn*(pool: ptr ThreadPool, task: proc() {.gcsafe.}) {.inline.} =
  spawn(pool[], task)

proc shutdown*(pool: var ThreadPool) {.raises: [].} =
  ## Gracefully terminates the thread pool, draining queued tasks and joining all worker threads.
  acquire(pool.lock)
  if pool.isShutDown:
    release(pool.lock)
    return
  pool.isShutDown = true
  atomics.store(pool.running, false, atomics.moRelease)
  wakeAll(pool.condWork)
  release(pool.lock)

  if atomics.load(pool.threadsStarted, atomics.moAcquire) and pool.threads.len > 0:
    for i in 0 ..< pool.threads.len:
      joinThread(pool.threads[i])
    pool.threads.setLen(0)

  acquire(pool.lock)
  if pool.queue != nil:
    while atomics.load(pool.queueCount, atomics.moRelaxed) > 0:
      var job = pool.queue[pool.queueHead]
      pool.queueHead = (pool.queueHead + 1) mod pool.queueCap
      pool.queueCount.atomicDec(1)
      if job.cleanup != nil and job.arg != nil:
        job.cleanup(job.arg)
    deallocShared(pool.queue)
    pool.queue = nil

  if pool.deques != nil:
    for i in 0 ..< pool.numWorkers:
      if pool.deques[i] != nil:
        var job: Job
        while pool.deques[i].pop(job):
          if job.cleanup != nil and job.arg != nil:
            job.cleanup(job.arg)
        destroyWorkStealDeque(pool.deques[i])
        pool.deques[i] = nil
    deallocShared(pool.deques)
    pool.deques = nil

  if pool.workerArgs != nil:
    deallocShared(pool.workerArgs)
    pool.workerArgs = nil

  release(pool.lock)
  pool.drainRetiredTasks(0'u64)
  deinitCondVar(pool.condWork)
  deinitSysLock(pool.lock)

proc shutdown*(pool: ptr ThreadPool) {.inline, raises: [].} =
  shutdown(pool[])

proc `=destroy`*(pool: var ThreadPool) {.raises: [].} =
  if atomics.load(pool.running, atomics.moRelaxed) and not pool.isShutDown:
    pool.shutdown()
  else:
    if pool.queue != nil or pool.deques != nil or pool.workerArgs != nil:
      acquire(pool.lock)
      if pool.queue != nil:
        while atomics.load(pool.queueCount, atomics.moRelaxed) > 0:
          var job = pool.queue[pool.queueHead]
          pool.queueHead = (pool.queueHead + 1) mod pool.queueCap
          pool.queueCount.atomicDec(1)
          if job.cleanup != nil and job.arg != nil:
            job.cleanup(job.arg)
        deallocShared(pool.queue)
        pool.queue = nil

      if pool.deques != nil:
        for i in 0 ..< pool.numWorkers:
          if pool.deques[i] != nil:
            destroyWorkStealDeque(pool.deques[i])
            pool.deques[i] = nil
        deallocShared(pool.deques)
        pool.deques = nil

      if pool.workerArgs != nil:
        deallocShared(pool.workerArgs)
        pool.workerArgs = nil
      release(pool.lock)
      deinitCondVar(pool.condWork)
      deinitSysLock(pool.lock)
    pool.drainRetiredTasks(0'u64)

# =============================================================================
# Process-Wide Default ThreadPool Singleton (Explicit Ownership & Override API)
# =============================================================================

var gDefaultPool: Atomic[pointer]
var gDefaultPoolOwned: Atomic[bool]
var gDefaultPoolLock: SpinLock

proc hasDefaultPool*(): bool {.inline, raises: [].} =
  ## Returns true if a default ThreadPool (owned or overridden) is currently installed.
  atomics.load(gDefaultPool, atomics.moAcquire) != nil

proc getDefaultPool*(): ptr ThreadPool {.raises: [].} =
  ## Returns the process-wide shared default ThreadPool instance, initializing it lazily
  ## on first use unless an explicit pool was installed via `setDefaultPool`.
  var p = cast[ptr ThreadPool](atomics.load(gDefaultPool, atomics.moAcquire))
  if p == nil:
    withLock(gDefaultPoolLock):
      p = cast[ptr ThreadPool](atomics.load(gDefaultPool, atomics.moAcquire))
      if p == nil:
        p = newThreadPool()
        atomics.store(gDefaultPoolOwned, true, atomics.moRelaxed)
        atomics.store(gDefaultPool, cast[pointer](p), atomics.moRelease)
  return p

proc setDefaultPool*(pool: ptr ThreadPool, takeOwnership: bool = false): ptr ThreadPool {.raises: [].} =
  ## Replaces the process-wide default ThreadPool with an explicit caller-provided pool.
  ## If an owned singleton pool was previously active, it is shut down and freed (returning `nil`).
  ## If a borrowed pool was previously installed (`takeOwnership = false`), returns it un-freed.
  withLock(gDefaultPoolLock):
    let prev = cast[ptr ThreadPool](atomics.load(gDefaultPool, atomics.moAcquire))
    let prevOwned = atomics.load(gDefaultPoolOwned, atomics.moRelaxed)
    atomics.store(gDefaultPoolOwned, if pool != nil: takeOwnership else: false, atomics.moRelaxed)
    atomics.store(gDefaultPool, cast[pointer](pool), atomics.moRelease)
    if prev != nil and prev != pool and prevOwned:
      prev.shutdown()
      deallocShared(prev)
      return nil
    return prev

proc spawn*(task: proc() {.gcsafe.}) {.inline.} =
  ## Spawns a task on the process-wide default ThreadPool.
  getDefaultPool().spawn(task)

proc shutdownThreadPool*() {.raises: [].} =
  ## Shuts down and frees the owned default ThreadPool, or detaches a borrowed override.
  if atomics.load(gDefaultPool, atomics.moAcquire) != nil:
    withLock(gDefaultPoolLock):
      let p = cast[ptr ThreadPool](atomics.load(gDefaultPool, atomics.moAcquire))
      let owned = atomics.load(gDefaultPoolOwned, atomics.moRelaxed)
      if p != nil:
        atomics.store(gDefaultPool, nil, atomics.moRelease)
        atomics.store(gDefaultPoolOwned, false, atomics.moRelaxed)
        if owned:
          p.shutdown()
          deallocShared(p)
