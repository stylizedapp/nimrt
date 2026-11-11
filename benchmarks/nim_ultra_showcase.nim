## benchmarks/nim_ultra_showcase.nim — Витрина скорости и читаемости Nim против Rust
##
## Использует модуль `algx/ultrasort` (3-Level Cache-Aware Hybrid MSD Radix + L1 Insertion Sort).

import std/strformat
import ../src/algx/ultrasort

type
  XorShift64 = object
    state: uint64

proc initXorShift64(seed: uint64): XorShift64 {.inline, raises: [].} =
  result.state = if seed == 0'u64: 0x54581234CAFEBEEF'u64 else: seed

proc nextI64(rng: var XorShift64): int64 {.inline, raises: [].} =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rng.state = x
  cast[int64](x)

proc fillData(data: var seq[int64], seed: uint64) =
  var rng = initXorShift64(seed)
  for i in 0 ..< data.len:
    data[i] = rng.nextI64()

proc main() =
  const
    N = 10_000_000
    Seed = 0xDEAD_BEEF_CAFE_1234'u64

  var data = newSeq[int64](N)
  fillData(data, Seed)

  var aux = newSeq[int64](N)
  for i in 0 ..< N:
    aux[i] = 1
  let ms = ultraSort(data, aux)
  doAssert isSorted(data), "UltraSort verification failed!"
  echo &"Nim UltraSort (10M int64, 4T): {ms:.2f} ms"

when isMainModule:
  main()
