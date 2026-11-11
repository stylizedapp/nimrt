## tests/test_ecosystem.nim — Полная проверка всех 10 модулей экосистемы Nim (corex + algx)

import std/[strformat]
import ../src/corex/corex
import ../src/algx/algx

# =============================================================================
# 1. Тест Result[T, E], оператора `?` и Zig-style `errdefer`
# =============================================================================

var cleanupTriggeredCount = 0

proc riskyComputation(x: int, shouldFail: bool): Result[int, string] =
  errdefer:
    inc(cleanupTriggeredCount)
  if shouldFail:
    return err[int, string]("Computation failed at step 1")
  ok[int, string](x * 10)

proc pipelineComputation(a: int, failSecond: bool): Result[int, string] =
  let step1 = ?riskyComputation(a, false)
  let step2 = ?riskyComputation(step1, failSecond)
  ok[int, string](step2 + 5)

# =============================================================================
# 2. Тест Алгебраических типов (`sumType`) и Pattern Matching (`match`)
# =============================================================================

sumType Expr:
  Lit(val: float)
  Add(left: float, right: float)
  Scale(factor: float, base: float)
  Zero

proc evalExpr(e: Expr): float =
  match e:
    Lit(val: v): v
    Add(left: l, right: r): l + r
    Scale(factor: f, base: b): f * b
    Zero: 0.0

# =============================================================================
# 3. Тест Трейтов и динамической диспетчеризации (`defTrait` / `Dyn`) без кучи
# =============================================================================

defTrait Metric:
  proc score(self): int
  proc label(self): string

type
  CpuBench = object
    ms: int
  MemBench = object
    kb: int

proc score*(b: CpuBench): int = 1000 - b.ms
proc label*(b: CpuBench): string = "CPU"

proc score*(b: MemBench): int = 5000 - b.kb
proc label*(b: MemBench): string = "RAM"

# =============================================================================
# 4. Тестовая структура для ZeroPack (POD VoxelEntity)
# =============================================================================

type
  VoxelPacket = object
    entityId: int64
    chunkX, chunkY, chunkZ: int32
    health: float32
    flags: uint32

# =============================================================================
# 5. Запуск всех 10 проверок
# =============================================================================

proc runAllTests() =
  echo "=== ЗАПУСК ПОЛНОГО ТЕСТ-СЬЮТА ЭКОСИСТЕМЫ NIM (COREX + ALGX) ==="

  # 1. Result + `?` + `errdefer`
  cleanupTriggeredCount = 0
  let rOk = pipelineComputation(4, failSecond = false)
  doAssert rOk.isOk and rOk.get() == 405
  doAssert cleanupTriggeredCount == 0
  let rErr = pipelineComputation(4, failSecond = true)
  doAssert rErr.isErr and rErr.error() == "Computation failed at step 1"
  doAssert cleanupTriggeredCount == 1
  echo "[OK] 01/10 Result[T, E], оператор `?` и `errdefer` (Zig-style)"

  # 2. sumType + match
  let items = [Lit(12.5), Add(3.0, 7.0), Scale(2.5, 4.0), Zero()]
  var total = 0.0
  for item in items: total += evalExpr(item)
  doAssert abs(total - 32.5) < 1e-9
  echo "[OK] 02/10 Алгебраические типы (sumType) и Pattern Matching (match)"

  # 3. Явные аллокаторы
  var stackBuf: array[512, byte]
  var fba = initFixedBufferAllocator(stackBuf)
  let stackAlloc = fba.allocator()
  let pInt = stackAlloc.create(42'i64).get()
  doAssert pInt[] == 42'i64
  echo "[OK] 03/10 Стековый аллокатор FixedBufferAllocator (0 обращений к куче ОС)"

  # 4. Контейнеры BufSeq / BufStr + автоматический контроль утечек testWithLeakCheck
  testWithLeakCheck("BufSeq and BufStr zero-leak check"):
    var seqRes = initBufSeq[int64](testAlloc, 4)
    doAssert seqRes.isOk
    var bseq = seqRes.get()
    defer: bseq.deinit()
    for k in 1 .. 20:
      doAssert bseq.tryAdd(int64(k * 10)).isOk
    doAssert bseq.len == 20 and bseq[19] == 200'i64

    var strRes = initBufStr(testAlloc, 16)
    doAssert strRes.isOk
    var bstr = strRes.get()
    defer: bstr.deinit()
    doAssert bstr.tryAppend("Nim ").isOk
    doAssert bstr.tryAppend("CoreX!").isOk
    doAssert $bstr == "Nim CoreX!"
  echo "[OK] 04/10 Аллокаторные контейнеры BufSeq[T] и BufStr + автопроверка утечек памяти"

  # 5. Трейты и динамическая диспетчеризация без кучи
  var c = CpuBench(ms: 60)
  var m = MemBench(kb: 131)
  let dynItems = [asDynMetric(c), asDynMetric(m)]
  doAssert dynItems[0].label() == "CPU" and dynItems[0].score() == 940
  doAssert dynItems[1].label() == "RAM" and dynItems[1].score() == 4869
  echo "[OK] 05/10 Fat-Pointer Трейты (defTrait / DynMetric) на стековых объектах"

  # 6. Property-Based Fuzzing (`quickCheck`)
  quickCheck("FastMap insert & lookup consistency", 200, rng):
    var mp = initFastMap[int64, int64](32)
    let k = cast[int64](rng.nextU64())
    let v = cast[int64](rng.nextU64())
    mp[k] = v
    mp.contains(k) and mp.getOrDefault(k, -1) == v
  echo "[OK] 06/10 Property-based фаззинг (quickCheck, 200 случайных проверок)"

  # 7. SwissTable / FastMap[K, V]
  var fmap = initFastMap[int64, int64](1024)
  for i in 1 .. 5000:
    fmap[int64(i * 7)] = int64(i * 100)
  doAssert fmap.len == 5000
  doAssert fmap.getOrDefault(3500'i64, -1) == 50_000'i64
  doAssert fmap.del(3500'i64)
  doAssert not fmap.contains(3500'i64) and fmap.len == 4999
  echo "[OK] 07/10 Сверхбыстрая хэш-таблица FastMap[K, V] (SwissTable L1 tags)"

  # 8. ZeroPack (Zero-Copy POD Binary & Fast JSON)
  var packets = newSeq[VoxelPacket](1000)
  for i in 0 ..< 1000:
    packets[i] = VoxelPacket(
      entityId: int64(i + 1),
      chunkX: int32(i * 2),
      chunkY: 64,
      chunkZ: int32(-i),
      health: 100.0'f32,
      flags: 0xFF'u32
    )
  let rawBytes = packBin(packets)
  let restored = unpackBin[seq[VoxelPacket]](rawBytes)
  doAssert restored.len == 1000 and restored[999].entityId == 1000 and restored[999].chunkZ == -999
  let js = toJsonFast(packets[0])
  doAssert js == """{"entityId":1,"chunkX":0,"chunkY":64,"chunkZ":0,"health":100.0,"flags":255}""", "Got: " & js
  echo "[OK] 08/10 Zero-Copy POD сериализация (packBin/unpackBin + toJsonFast)"

  # 9. SIMD Scan / 8-Way Superscalar Analytics
  var vecA = newSeq[int64](10_000)
  var vecB = newSeq[int64](10_000)
  for i in 0 ..< 10_000:
    vecA[i] = int64(i + 1)
    vecB[i] = 2'i64
  doAssert fastSum(vecA) == 50_005_000'i64
  doAssert fastDotProduct(vecA, vecB) == 100_010_000'i64
  let (mn, mx) = fastMinMax(vecA)
  doAssert mn == 1'i64 and mx == 10_000'i64
  doAssert fastCountGreater(vecA, 5000'i64) == 5000
  echo "[OK] 09/10 Векторизованная аналитика массивов (fastSum, fastDotProduct, fastCountGreater)"

  # 10. UltraSort
  var data = newSeq[int64](100_000)
  var aux = newSeq[int64](100_000)
  var state = 0xCAFE_BABE_1234_5678'u64
  for i in 0 ..< data.len:
    state = state xor (state shl 13)
    state = state xor (state shr 7)
    state = state xor (state shl 17)
    data[i] = cast[int64](state)
  let ms = ultraSort(data, aux)
  doAssert isSorted(data)
  echo &"[OK] 10/10 Алгоритм UltraSort (100 000 int64 отсортировано за {ms:.2f} мс)"
  echo "=== ВСЕ 10 ПОДСИСТЕМ ЭКОСИСТЕМЫ ПРОТЕСТИРОВАНЫ БЕЗ ОШИБОК ==="

when isMainModule:
  runAllTests()
