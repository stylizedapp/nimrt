import corex
import std/os

var gWatchdogDone = initAtomic(false)

proc watchdog() {.thread.} =
  sleep(5000)
  if not gWatchdogDone.load(moAcquire):
    echo "[FAIL] DEADLOCK detected (5s timeout)"
    quit(1)

type
  TestContext = object
    pool: ptr ThreadPool
    stop: Atomic[bool]

proc pfWorker(ctx: ptr TestContext) {.thread.} =
  while not ctx.stop.load(moRelaxed):
    try:
      ctx.pool.parallelFor(0, 500, proc(s, e: int) =
        discard
      )
    except CatchableError:
      break

proc main() =
  var watchdogThread: Thread[void]
  createThread(watchdogThread, watchdog)

  for iter in 1 .. 50:
    var pool = newThreadPool(8)
    var ctx: TestContext
    ctx.pool = pool
    ctx.stop.store(false, moRelaxed)

    var thrs: array[2, Thread[ptr TestContext]]
    for i in 0 ..< 2:
      createThread(thrs[i], pfWorker, addr ctx)

    sleep(1)
    ctx.stop.store(true, moRelease)
    pool.shutdown()

    for i in 0 ..< 2:
      joinThread(thrs[i])

    deallocShared(pool)

  gWatchdogDone.store(true, moRelease)
  echo "[PASS] 50 shutdown iterations without deadlock"
  quit(0)

when isMainModule:
  main()
