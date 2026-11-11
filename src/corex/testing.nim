## corex/testing — Тестовый раннер с автопроверкой утечек памяти, фаззингом и микробенчмарком
##
## Объединяет лучшие идеи `std.testing` из Zig (автоматический контроль утечек памяти),
## `cargo bench` из Rust и `hypothesis` из Python (property-based генерация тестов).

import std/[monotimes, times, strformat]
import ./allocators

type
  BenchStats* = object
    name*: string
    iterations*: int
    minMs*: float
    avgMs*: float
    maxMs*: float
    opsPerSec*: float

  FuzzRng* = object
    state*: uint64

proc initFuzzRng*(seed: uint64 = 0x9E37_79B9_7F4A_7C15'u64): FuzzRng {.inline, raises: [].} =
  FuzzRng(state: if seed == 0: 0x9E37_79B9_7F4A_7C15'u64 else: seed)

proc nextU64*(r: var FuzzRng): uint64 {.inline, raises: [].} =
  var z = r.state + 0x9E37_79B9_7F4A_7C15'u64
  r.state = z
  z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
  z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
  z xor (z shr 31)

proc nextInt*(r: var FuzzRng, lowVal, highVal: int): int {.inline, raises: [].} =
  let span = uint64(highVal - lowVal + 1)
  lowVal + int(r.nextU64() mod span)

template testWithLeakCheck*(testName: string, body: untyped) =
  ## Запускает тест с автоматическим `TrackingAllocator` (переменная `testAlloc` доступна внутри).
  ## Если после завершения блока (и всех его `defer`) осталась неосвобождённая память — тест аварийно падает.
  block:
    var tracker = initTrackingAllocator()
    let testAlloc {.inject, used.} = tracker.allocator()
    block:
      body
    if tracker.hasLeaks():
      raise newException(AssertionDefect,
        "[LEAK DETECTED] В тесте '" & testName & "' утечка памяти: " &
        $tracker.activeAllocs & " аллокаций (" & $tracker.activeBytes & " байт)")

template quickCheck*(propName: string, runs: int, rngVar: untyped, body: untyped) =
  ## Property-based фаззинг: прогоняет свойство `runs` раз на псевдослучайных данных.
  block:
    var `rngVar` {.inject.} = initFuzzRng(0xCAFE_BEEF_1337_0001'u64)
    for iterIdx in 0 ..< runs:
      let okProp = block:
        body
      if not okProp:
        raise newException(AssertionDefect,
          "[QUICKCHECK FAILED] Свойство '" & propName & "' нарушено на итерации " & $iterIdx)

template bench*(benchName: string, iters: int, totalItems: int, body: untyped): BenchStats =
  ## Замеряет `min`, `avg`, `max` время в миллисекундах и пропускную способность (элементов/сек).
  block:
    var minTime = 1e18
    var maxTime = 0.0
    var sumTime = 0.0
    for i in 0 ..< iters:
      let t0 = getMonoTime()
      body
      let elapsedMs = (getMonoTime() - t0).inMicroseconds.float / 1000.0
      if elapsedMs < minTime: minTime = elapsedMs
      if elapsedMs > maxTime: maxTime = elapsedMs
      sumTime += elapsedMs
    let avgTime = sumTime / iters.float
    let ops = if minTime > 0.0: (totalItems.float / (minTime / 1000.0)) else: 0.0
    BenchStats(
      name: benchName,
      iterations: iters,
      minMs: minTime,
      avgMs: avgTime,
      maxMs: maxTime,
      opsPerSec: ops
    )

proc formatStats*(s: BenchStats): string =
  let mops = s.opsPerSec / 1_000_000.0
  &"{s.name:<36} | min: {s.minMs:>7.2f} ms | avg: {s.avgMs:>7.2f} ms | peak: {mops:>7.2f} M ops/s"
