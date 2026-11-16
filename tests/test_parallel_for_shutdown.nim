import corex
import std/os

var gWatchdogDone = initAtomic(false)
var gIterProgress = initAtomic(0)

proc watchdog() {.thread.} =
  var lastIter = -1
  var stalledMs = 0
  while not gWatchdogDone.load(moAcquire):
    sleep(100)
    let cur = gIterProgress.load(moAcquire)
    if cur != lastIter:
      lastIter = cur
      stalledMs = 0
    else:
      stalledMs += 100
      if stalledMs >= 3000:
        echo "[FAIL] DEADLOCK detected (3s stall at iter ", cur, ")"
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
    gIterProgress.store(iter, moRelease)
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
