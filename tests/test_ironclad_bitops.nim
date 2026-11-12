## tests/test_ironclad_bitops.nim
## Independent adversarial verification suite for bit operations and bitsets.
## Adheres strictly to ground-truth specifications. Never tailored.

import std/[strformat, math]
import corex/bitops

# Independent PRNG for deterministic pseudo-random fuzzing
type
  Prng = object
    state: uint64

proc initPrng(seed: uint64 = 0x8541_5B2E_694C_B79F'u64): Prng =
  Prng(state: seed)

proc nextU64(p: var Prng): uint64 =
  p.state = p.state + 0x9E37_79B9_7F4A_7C15'u64
  var z = p.state
  z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
  z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
  z xor (z shr 31)

# =============================================================================
# Reference Implementations (Ground Truth)
# =============================================================================

proc refPopcount(x: uint64): int =
  var c = 0
  for i in 0 .. 63:
    if ((x shr i) and 1'u64) != 0'u64:
      inc c
  c

proc refClz(x: uint64): int =
  if x == 0'u64: return 64
  for i in countdown(63, 0):
    if ((x shr i) and 1'u64) != 0'u64:
      return 63 - i
  64

proc refCtz(x: uint64): int =
  if x == 0'u64: return 64
  for i in 0 .. 63:
    if ((x shr i) and 1'u64) != 0'u64:
      return i
  64

proc refRotateLeft(x: uint64, k: int): uint64 =
  let s = (k mod 64 + 64) mod 64
  if s == 0: x
  else: (x shl s) or (x shr (64 - s))

proc refRotateRight(x: uint64, k: int): uint64 =
  let s = (k mod 64 + 64) mod 64
  if s == 0: x
  else: (x shr s) or (x shl (64 - s))

proc refReverseBits(x: uint64): uint64 =
  var res = 0'u64
  for i in 0 .. 63:
    if ((x shr i) and 1'u64) != 0'u64:
      res = res or (1'u64 shl (63 - i))
  res

proc refIsPowerOfTwo(x: uint64): bool =
  x > 0'u64 and (x and (x - 1'u64)) == 0'u64

proc refNextPowerOfTwo(x: uint64): uint64 =
  if x <= 1'u64: return 1'u64
  if x > (1'u64 shl 62): return 1'u64 shl 63
  var p = 1'u64
  while p < x:
    p = p shl 1
  p

proc refHasZeroByte(word: uint64): bool =
  for i in 0 .. 7:
    let b = uint8((word shr (i * 8)) and 0xFF'u64)
    if b == 0'u8: return true
  false

proc refFirstMatchingByte(word: uint64, byteVal: uint8): int =
  for i in 0 .. 7:
    let b = uint8((word shr (i * 8)) and 0xFF'u64)
    if b == byteVal: return i
  -1

template callClz(x: uint64): int =
  when compiles(countLeadingZeros(x)):
    countLeadingZeros(x)
  else:
    clz(x)

template callCtz(x: uint64): int =
  when compiles(countTrailingZeros(x)):
    countTrailingZeros(x)
  else:
    ctz(x)

template callNextPow2(x: uint64): uint64 =
  when compiles(nextPowerOfTwo(x)):
    nextPowerOfTwo(x)
  else:
    nextPow2(x)

# =============================================================================
# Test Suite: Intrinsics
# =============================================================================

proc testIntrinsics() =
  echo "[test_ironclad_bitops] Testing bit intrinsics against ground truth..."

  let fixedTestCases: seq[uint64] = @[
    0'u64, 1'u64, 2'u64, 3'u64, 0x7FFFFFFFFFFFFFFF'u64, 0x8000000000000000'u64,
    0xFFFFFFFFFFFFFFFF'u64, 0x5555555555555555'u64, 0xAAAAAAAAAAAAAAAA'u64,
    0x3333333333333333'u64, 0xCCCCCCCCCCCCCCCC'u64, 0x0F0F0F0F0F0F0F0F'u64,
    0xF0F0F0F0F0F0F0F0'u64, 0x00FF00FF00FF00FF'u64, 0xFF00FF00FF00FF00'u64,
    0x0000FFFF0000FFFF'u64, 0xFFFF0000FFFF0000'u64, 0x00000000FFFFFFFF'u64,
    0xFFFFFFFF00000000'u64
  ]

  # 1. Fixed cases + all 64 bit positions
  for v in fixedTestCases:
    doAssert popcount(v) == refPopcount(v), &"popcount failed for {v:#x}"
    doAssert callClz(v) == refClz(v), &"clz failed for {v:#x}"
    doAssert callCtz(v) == refCtz(v), &"ctz failed for {v:#x}"
    doAssert reverseBits(v) == refReverseBits(v), &"reverseBits failed for {v:#x}"
    doAssert isPowerOfTwo(v) == refIsPowerOfTwo(v), &"isPowerOfTwo failed for {v:#x}"
    if v <= (1'u64 shl 62):
      doAssert callNextPow2(v) == refNextPowerOfTwo(v), &"nextPowerOfTwo failed for {v:#x}"

  for i in 0 .. 63:
    let singleBit = 1'u64 shl i
    doAssert popcount(singleBit) == 1
    doAssert callClz(singleBit) == 63 - i
    doAssert callCtz(singleBit) == i
    doAssert reverseBits(singleBit) == (1'u64 shl (63 - i))
    doAssert isPowerOfTwo(singleBit) == true

    let inverted = not singleBit
    doAssert popcount(inverted) == 63
    doAssert callClz(inverted) == (if i == 63: 1 else: 0)
    doAssert callCtz(inverted) == (if i == 0: 1 else: 0)
    doAssert reverseBits(inverted) == not (1'u64 shl (63 - i))
    doAssert isPowerOfTwo(inverted) == (inverted == 1)

    for k in 0 .. 128:
      doAssert rotateLeft(singleBit, k) == refRotateLeft(singleBit, k)
      doAssert rotateRight(singleBit, k) == refRotateRight(singleBit, k)

  # 2. 100,000 random samples
  var prng = initPrng(0xDEAD_BEEF_CAFE_BABE'u64)
  for iter in 0 ..< 100_000:
    let v = prng.nextU64()
    doAssert popcount(v) == refPopcount(v), &"Random popcount failed for {v:#x}"
    doAssert callClz(v) == refClz(v), &"Random clz failed for {v:#x}"
    doAssert callCtz(v) == refCtz(v), &"Random ctz failed for {v:#x}"
    doAssert reverseBits(v) == refReverseBits(v), &"Random reverseBits failed for {v:#x}"
    doAssert isPowerOfTwo(v) == refIsPowerOfTwo(v), &"Random isPowerOfTwo failed for {v:#x}"

    let rot = int(v and 127'u64)
    doAssert rotateLeft(v, rot) == refRotateLeft(v, rot), &"Random rotateLeft failed for {v:#x}, rot={rot}"
    doAssert rotateRight(v, rot) == refRotateRight(v, rot), &"Random rotateRight failed for {v:#x}, rot={rot}"

  echo "[test_ironclad_bitops] Bit intrinsics verified: 100,000+ checks PASSED."

# =============================================================================
# Test Suite: BitSet[N]
# =============================================================================

proc testBitSetGeneric[N: static[int]]() =
  echo &"[test_ironclad_bitops] Testing BitSet[{N}]..."
  var bs: BitSet[N]
  var refArr: array[N, bool]

  # Initially all zero
  doAssert bs.count() == 0
  doAssert bs.firstSet() == -1
  doAssert bs.firstClear() == 0

  for i in 0 ..< N:
    doAssert bs.testBit(i) == false

  # Set individual bits sequentially
  for i in 0 ..< N:
    bs.setBit(i)
    refArr[i] = true
    doAssert bs.testBit(i) == true
    doAssert bs.count() == i + 1
    doAssert bs.firstSet() == 0
    let expectedClear = if i + 1 < N: i + 1 else: -1
    doAssert bs.firstClear() == expectedClear

  # All set
  doAssert bs.count() == N
  doAssert bs.firstSet() == 0
  doAssert bs.firstClear() == -1

  # Clear from beginning
  for i in 0 ..< N:
    bs.clearBit(i)
    refArr[i] = false
    doAssert bs.testBit(i) == false
    doAssert bs.count() == N - (i + 1)
    doAssert bs.firstClear() == 0
    let expectedSet = if i + 1 < N: i + 1 else: -1
    doAssert bs.firstSet() == expectedSet

  # Randomized fuzzing against array[N, bool]
  var prng = initPrng(uint64(N) * 0x1234_5678_9ABC'u64)
  for iter in 0 ..< 20_000:
    let idx = int(prng.nextU64() mod uint64(N))
    let action = (prng.nextU64() and 1'u64) == 1'u64
    if action:
      bs.setBit(idx)
      refArr[idx] = true
    else:
      bs.clearBit(idx)
      refArr[idx] = false

    doAssert bs.testBit(idx) == refArr[idx]

    if iter mod 500 == 0:
      var trueCount = 0
      var trueFirstSet = -1
      var trueFirstClear = -1
      for j in 0 ..< N:
        if refArr[j]:
          inc trueCount
          if trueFirstSet == -1: trueFirstSet = j
        else:
          if trueFirstClear == -1: trueFirstClear = j
      doAssert bs.count() == trueCount, &"BitSet[{N}] count mismatch at iter {iter}"
      doAssert bs.firstSet() == trueFirstSet, &"BitSet[{N}] firstSet mismatch at iter {iter}"
      doAssert bs.firstClear() == trueFirstClear, &"BitSet[{N}] firstClear mismatch at iter {iter}"

  # Test bitwise operators
  var a, b: BitSet[N]
  var refA, refB: array[N, bool]
  for i in 0 ..< N:
    if (i and 1) == 0:
      a.setBit(i)
      refA[i] = true
    if (i mod 3) == 0:
      b.setBit(i)
      refB[i] = true

  let cAnd = a and b
  let cOr = a or b
  let cXor = a xor b
  let cNot = not a

  for i in 0 ..< N:
    doAssert cAnd.testBit(i) == (refA[i] and refB[i])
    doAssert cOr.testBit(i) == (refA[i] or refB[i])
    doAssert cXor.testBit(i) == (refA[i] xor refB[i])
    doAssert cNot.testBit(i) == (not refA[i])

  echo &"[test_ironclad_bitops] BitSet[{N}] PASSED."

proc testBitSets() =
  testBitSetGeneric[64]()
  testBitSetGeneric[128]()
  testBitSetGeneric[256]()

# =============================================================================
# Test Suite: SWAR Byte Primitives
# =============================================================================

proc testSwar() =
  echo "[test_ironclad_bitops] Testing SWAR byte primitives..."

  # 1. hasZeroByte
  # Word with no zero byte
  doAssert hasZeroByte(0x0102030405060708'u64) == false
  doAssert hasZeroByte(0xFFFFFFFFFFFFFFFF'u64) == false
  doAssert hasZeroByte(0x8080808080808080'u64) == false
  doAssert hasZeroByte(0x7F7F7F7F7F7F7F7F'u64) == false

  # Words with zero bytes at each position
  for pos in 0 .. 7:
    var w = 0xAAAAAAAAAAAAAAAA'u64
    let mask = not (0xFF'u64 shl (pos * 8))
    w = w and mask
    doAssert hasZeroByte(w) == true, &"hasZeroByte failed for zero byte at pos {pos}"

  # 2. matchByteMask64 and firstMatchingByteIndex
  for targetByte in 0'u8 .. 255'u8:
    # Construct base word with non-target bytes
    let nonTarget = if targetByte == 0xAA'u8: 0x55'u8 else: 0xAA'u8
    var baseWord = 0'u64
    for i in 0 .. 7:
      baseWord = baseWord or (uint64(nonTarget) shl (i * 8))

    # Test no match
    let maskNone = matchByteMask64(baseWord, targetByte)
    doAssert firstMatchingByteIndex(maskNone) == -1, &"Expected -1 for no match of {targetByte:#x}"

    # Test single match at each position
    for pos in 0 .. 7:
      var singleWord = baseWord
      singleWord = singleWord and (not (0xFF'u64 shl (pos * 8)))
      singleWord = singleWord or (uint64(targetByte) shl (pos * 8))

      let mask = matchByteMask64(singleWord, targetByte)
      let idx = firstMatchingByteIndex(mask)
      doAssert idx == pos, &"Expected match at pos {pos}, got {idx} for target {targetByte:#x}"

    # Test multiple matches: pos 2 and pos 5 -> must return pos 2 (first)
    var multiWord = baseWord
    multiWord = multiWord and (not ((0xFF'u64 shl (2 * 8)) or (0xFF'u64 shl (5 * 8))))
    multiWord = multiWord or (uint64(targetByte) shl (2 * 8)) or (uint64(targetByte) shl (5 * 8))

    let multiMask = matchByteMask64(multiWord, targetByte)
    doAssert firstMatchingByteIndex(multiMask) == 2, &"Expected first match at pos 2, got {firstMatchingByteIndex(multiMask)}"

    # Test all match
    var allWord = 0'u64
    for i in 0 .. 7:
      allWord = allWord or (uint64(targetByte) shl (i * 8))
    let allMask = matchByteMask64(allWord, targetByte)
    doAssert firstMatchingByteIndex(allMask) == 0, &"Expected first match at pos 0 for all match"

  echo "[test_ironclad_bitops] SWAR byte primitives PASSED."

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  testIntrinsics()
  testBitSets()
  testSwar()
  echo "\n>>> [test_ironclad_bitops] ALL TESTS PASSED UNCOMPROMISINGLY <<<"
