## corex/concurrency/parallel — Cooperative Range-Partitioned `parallelFor`
##
## Partitions `[start, end)` across `ThreadPool` workers with cooperative caller execution
## and `Result`-based error handling (`tryParallelFor`) without catching `Defect`.

import ./primitives
import ./pool
import ../workstealing
import ../result

type
  ChunkJob = object
    s: int
    e: int
    wg: ptr WaitGroup
    fn: ptr proc(s, e: int) {.gcsafe.}

proc runChunkJob(p: pointer) {.nimcall, gcsafe.} =
  let job = cast[ptr ChunkJob](p)
  try:
    job.fn[](job.s, job.e)
  finally:
    job.wg.done()

proc parallelForImpl(
  pool: var ThreadPool,
  start, `end`: int,
  fn: proc(s, e: int) {.gcsafe.},
  fallbackSyncOnStop: bool
): Result[void, ConcurrencyError] =
  if start >= `end`:
    return ok[void, ConcurrencyError]()

  let ensureRes = pool.tryEnsureWorkers()
  if ensureRes.isErr:
    if fallbackSyncOnStop:
      fn(start, `end`)
      return ok[void, ConcurrencyError]()
    return ensureRes

  if not pool.isRunning():
    if fallbackSyncOnStop:
      fn(start, `end`)
      return ok[void, ConcurrencyError]()
    return err[void, ConcurrencyError](cePoolStopped)

  let totalItems = `end` - start
  let numWorkers = pool.effectiveWorkerCount()
  let numChunks = min(totalItems, numWorkers * 2)
  let chunkSize = (totalItems + numChunks - 1) div numChunks

  var wg = initWaitGroup()
  let wgPtr = addr wg
  let fnPtr = unsafeAddr fn

  var jobs = newSeq[ChunkJob](numChunks)
  var cur = start
  var idx = 0
  var pushedChunks = 0
  let poolPtr = addr pool
  let isWorker = isWorkerOf(poolPtr)
  var stoppedDuringPush = false

  try:
    while cur < `end`:
      let chunkEnd = min(cur + chunkSize, `end`)
      jobs[idx].s = cur
      jobs[idx].e = chunkEnd
      jobs[idx].wg = wgPtr
      jobs[idx].fn = fnPtr

      wgPtr.add(1)
      let job = Job(fn: runChunkJob, arg: addr jobs[idx], cleanup: nil)
      let subRes = pool.trySubmitJob(job)
      if subRes.isErr:
        wgPtr.add(-1) # rollback: task not queued, done() will not be called
        stoppedDuringPush = true
        break

      inc(pushedChunks)
      cur = chunkEnd
      inc(idx)

    if isWorker:
      pool.wakeAllWorkers()

    # Cooperative execution while waiting for chunks
    if isWorker:
      while wgPtr.value > 0:
        var j: Job
        if poolPtr.popLocalWork(j):
          execute(j)
        elif poolPtr.popInjection(currentWorkerId(), j):
          execute(j)
        elif poolPtr.stealWork(currentWorkerId(), j):
          execute(j)
        else:
          break
    else:
      while wgPtr.value > 0:
        var j: Job
        if poolPtr.popInjection(-1, j):
          execute(j)
        else:
          break

    wgPtr.wait()
  except CatchableError:
    if pushedChunks > 0:
      wgPtr.wait()
    raise

  if stoppedDuringPush:
    if fallbackSyncOnStop and cur < `end`:
      fn(cur, `end`)
      return ok[void, ConcurrencyError]()
    return err[void, ConcurrencyError](cePoolStopped)

  ok[void, ConcurrencyError]()

proc tryParallelFor*(pool: var ThreadPool, start, `end`: int, fn: proc(s, e: int) {.gcsafe.}): Result[void, ConcurrencyError] =
  ## Partitions [start, end) across worker threads, returning Err(cePoolStopped) if stopped.
  parallelForImpl(pool, start, `end`, fn, fallbackSyncOnStop = false)

proc tryParallelFor*(pool: ptr ThreadPool, start, `end`: int, fn: proc(s, e: int) {.gcsafe.}): Result[void, ConcurrencyError] {.inline.} =
  tryParallelFor(pool[], start, `end`, fn)

proc parallelFor*(pool: var ThreadPool, start, `end`: int, fn: proc(s, e: int) {.gcsafe.}) =
  ## Partitions the half-open range [start, end) into balanced chunks across worker threads.
  ## Blocks until all chunks complete. Falls back to synchronous execution if pool is shutting down.
  let res = parallelForImpl(pool, start, `end`, fn, fallbackSyncOnStop = true)
  if res.isErr:
    raiseAssert("parallelFor failed: " & $res.error)

proc parallelFor*(pool: ptr ThreadPool, start, `end`: int, fn: proc(s, e: int) {.gcsafe.}) {.inline.} =
  parallelFor(pool[], start, `end`, fn)

proc parallelFor*(pool: var ThreadPool, start, `end`: int, fn: proc(i: int) {.gcsafe.}) =
  ## Single-item overload of parallelFor: Calls fn(i) for each i in [start, end).
  pool.parallelFor(start, `end`, proc(s, e: int) {.gcsafe.} =
    for i in s ..< e:
      fn(i)
  )

proc parallelFor*(pool: ptr ThreadPool, start, `end`: int, fn: proc(i: int) {.gcsafe.}) {.inline.} =
  parallelFor(pool[], start, `end`, fn)

proc parallelFor*(start, `end`: int, fn: proc(s, e: int) {.gcsafe.}) {.inline.} =
  ## Runs parallelFor on the process-wide default ThreadPool.
  getDefaultPool().parallelFor(start, `end`, fn)

proc parallelFor*(start, `end`: int, fn: proc(i: int) {.gcsafe.}) {.inline.} =
  ## Runs single-item parallelFor on the process-wide default ThreadPool.
  getDefaultPool().parallelFor(start, `end`, fn)
