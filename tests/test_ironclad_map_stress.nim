## tests/test_ironclad_map_stress.nim
## Independent adversarial stress and collision test for FastMap and BufMap.
## Verifies against std/tables.Table ground truth, tests 100% hash collision chains,
## and enforces 0-byte memory leak guarantee under ARC/ORC with TrackingAllocator.

import std/[tables, strformat, hashes]
import algx/swissmap
import corex/[bufmap, allocators, adt, result]

# Independent PRNG
type
  Prng = object
    state: uint64

proc initPrng(seed: uint64 = 0xCAFE_BABE_1234_5678'u64): Prng =
  Prng(state: seed)

proc nextU64(p: var Prng): uint64 =
  p.state = p.state + 0x9E37_79B9_7F4A_7C15'u64
  var z = p.state
  z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9'u64
  z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EB'u64
  z xor (z shr 31)

proc nextInt(p: var Prng, minVal, maxVal: int): int =
  let span = uint64(maxVal - minVal + 1)
  minVal + int(p.nextU64() mod span)

# =============================================================================
# Colliding Key for Adversarial Hash Collision Testing
# =============================================================================

type
  CollidingKey = object
    id: int
    cluster: int

proc `==`*(a, b: CollidingKey): bool =
  a.id == b.id and a.cluster == b.cluster

proc hash*(k: CollidingKey): Hash =
  # All keys with same cluster return the exact same hash value!
  hash(k.cluster)

# =============================================================================
# FastMap Stress Test (200,000+ operations against Table)
# =============================================================================

proc testFastMapStress() =
  echo "[test_ironclad_map_stress] Running 200,000+ randomized ops on FastMap vs Table..."

  var fmap = initFastMap[int, string](64)
  var tbl = initTable[int, string]()
  var prng = initPrng(0x9876_5432_10FE_DCBA'u64)

  const TotalOps = 250_000
  const KeyRange = 25_000

  for op in 0 ..< TotalOps:
    let roll = prng.nextInt(0, 99)
    let k = prng.nextInt(-KeyRange, KeyRange)

    if roll < 45: # 45% Insert / Update
      let v = "val_" & $prng.nextInt(0, 1_000_000)
      fmap.put(k, v)
      tbl[k] = v
    elif roll < 70: # 25% Query
      let inTbl = k in tbl
      let inFmap = fmap.contains(k)
      doAssert inFmap == inTbl, &"FastMap contains mismatch for key {k} at op {op}"
      if inTbl:
        let valFmap = fmap.getOrDefault(k, "NOT_FOUND")
        let valTbl = tbl[k]
        doAssert valFmap == valTbl, &"FastMap value mismatch for key {k}: got {valFmap}, expected {valTbl}"
    elif roll < 90: # 20% Delete
      let inTbl = k in tbl
      let deleted = fmap.del(k)
      doAssert deleted == inTbl, &"FastMap delete mismatch for key {k} at op {op}"
      if inTbl:
        tbl.del(k)
    else: # 10% Miss query outside range
      let missKey = KeyRange + 10_000 + (op mod 1000)
      doAssert fmap.contains(missKey) == false
      doAssert fmap.getOrDefault(missKey, "DEF") == "DEF"
      doAssert fmap.get(missKey).isNone()

    if op mod 25_000 == 0:
      doAssert fmap.len == tbl.len, &"Length mismatch at op {op}: FastMap={fmap.len}, Table={tbl.len}"

  doAssert fmap.len == tbl.len
  # Verify every remaining entry matches Table exactly
  for k, v in tbl:
    doAssert fmap.contains(k), &"FastMap missing final key {k}"
    doAssert fmap.getOrDefault(k, "") == v, &"FastMap value mismatch for final key {k}"
    let optVal = fmap.get(k)
    doAssert optVal.isSome() and optVal.get() == v, &"FastMap.get() mismatch for {k}"

  echo &"[test_ironclad_map_stress] FastMap stress passed: {TotalOps} ops matched Table ground truth."

# =============================================================================
# FastMap Collision Attack Test (10,000 identical hash keys)
# =============================================================================

proc testFastMapCollisionAttack() =
  echo "[test_ironclad_map_stress] Testing FastMap collision attack (10,000 keys with identical hash)..."

  var cmap = initFastMap[CollidingKey, string](64)
  const NumCollisions = 10_000

  # Insert 10,000 keys all mapped to cluster 999 (same hash)
  for i in 0 ..< NumCollisions:
    let k = CollidingKey(id: i, cluster: 999)
    let v = &"collision_val_{i}"
    cmap.put(k, v)

  doAssert cmap.len == NumCollisions, &"Expected len {NumCollisions}, got {cmap.len}"

  # Verify all 10,000 keys can be queried correctly without loss
  for i in 0 ..< NumCollisions:
    let k = CollidingKey(id: i, cluster: 999)
    let expectedVal = &"collision_val_{i}"
    doAssert cmap.contains(k), &"FastMap lost colliding key {i}"
    doAssert cmap.getOrDefault(k, "") == expectedVal, &"FastMap value corrupted for colliding key {i}"

  # Update half of them
  for i in 0 ..< (NumCollisions div 2):
    let k = CollidingKey(id: i, cluster: 999)
    let updatedVal = &"updated_{i}"
    cmap.put(k, updatedVal)

  doAssert cmap.len == NumCollisions

  for i in 0 ..< (NumCollisions div 2):
    let k = CollidingKey(id: i, cluster: 999)
    doAssert cmap.getOrDefault(k, "") == &"updated_{i}"

  # Delete even keys
  var deletedCount = 0
  for i in 0 ..< NumCollisions:
    if (i and 1) == 0:
      let k = CollidingKey(id: i, cluster: 999)
      doAssert cmap.del(k) == true, &"Failed to delete colliding key {i}"
      inc deletedCount

  doAssert cmap.len == NumCollisions - deletedCount

  # Verify odd keys remain completely intact
  for i in 0 ..< NumCollisions:
    let k = CollidingKey(id: i, cluster: 999)
    if (i and 1) == 0:
      doAssert cmap.contains(k) == false
    else:
      let expected = if i < (NumCollisions div 2): &"updated_{i}" else: &"collision_val_{i}"
      doAssert cmap.contains(k) == true, &"Odd key {i} inadvertently lost after deletion of even keys"
      doAssert cmap.getOrDefault(k, "") == expected

  echo "[test_ironclad_map_stress] FastMap collision attack test PASSED."

# =============================================================================
# BufMap Stress & Leak Test (TrackingAllocator under ARC/ORC)
# =============================================================================

proc testBufMapStressAndLeak() =
  echo "[test_ironclad_map_stress] Testing BufMap 200,000+ ops and 0-byte leak guarantee..."

  var tracker = initTrackingAllocator()
  let alloc = tracker.allocator()

  block:
    var bmapRes = initBufMap[int, string](alloc, 64)
    doAssert bmapRes.isOk
    var bmap = bmapRes.unwrap()
    var tbl = initTable[int, string]()
    var prng = initPrng(0x55AA_1234_FEDC_BA98'u64)

    const TotalOps = 250_000
    const KeyRange = 25_000

    for op in 0 ..< TotalOps:
      let roll = prng.nextInt(0, 99)
      let k = prng.nextInt(-KeyRange, KeyRange)

      if roll < 45: # 45% Insert / Update
        let v = "bval_" & $prng.nextInt(0, 1_000_000)
        let putRes = bmap.put(k, v)
        doAssert putRes.isOk
        tbl[k] = v
      elif roll < 70: # 25% Query
        let inTbl = k in tbl
        let inBmap = bmap.contains(k)
        doAssert inBmap == inTbl, &"BufMap contains mismatch for key {k} at op {op}"
        if inTbl:
          let opt = bmap.get(k)
          doAssert opt.isSome, &"BufMap get returned None for existing key {k}"
          doAssert opt.get() == tbl[k], &"BufMap value mismatch for key {k}"
      elif roll < 90: # 20% Delete
        let inTbl = k in tbl
        let deleted = bmap.del(k)
        doAssert deleted == inTbl, &"BufMap delete mismatch for key {k} at op {op}"
        if inTbl:
          tbl.del(k)
      else: # 10% Miss query
        let missKey = KeyRange + 15_000 + (op mod 1000)
        doAssert bmap.contains(missKey) == false
        doAssert bmap.get(missKey).isNone

      if op mod 25_000 == 0:
        doAssert bmap.len == tbl.len, &"BufMap len mismatch at op {op}: BufMap={bmap.len}, Table={tbl.len}"

    doAssert bmap.len == tbl.len
    for k, v in tbl:
      doAssert bmap.contains(k)
      doAssert bmap.get(k).get() == v

    # Clear test
    bmap.clear()
    doAssert bmap.len == 0
    doAssert bmap.contains(1) == false

    # Re-insert after clear
    for i in 0 ..< 5_000:
      let res = bmap.put(i, &"reinsert_{i}")
      doAssert res.isOk
    doAssert bmap.len == 5_000

    # End of block: bmap goes out of scope and `=destroy` must be invoked automatically!

  # Verify 0 memory leaks in TrackingAllocator!
  echo &"[test_ironclad_map_stress] TrackingAllocator stats: allocCount={tracker.allocCount}, freeCount={tracker.freeCount}, activeAllocs={tracker.activeAllocs}, activeBytes={tracker.activeBytes}"
  doAssert tracker.activeAllocs == 0, &"LEAK DETECTED: activeAllocs={tracker.activeAllocs}"
  doAssert tracker.activeBytes == 0, &"LEAK DETECTED: activeBytes={tracker.activeBytes}"
  doAssert tracker.allocCount == tracker.freeCount, &"LEAK DETECTED: allocCount({tracker.allocCount}) != freeCount({tracker.freeCount})"
  doAssert not tracker.hasLeaks(), "TrackingAllocator reported leaks!"

  echo "[test_ironclad_map_stress] BufMap stress and leak check PASSED with 0 bytes leaked."

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  testFastMapStress()
  testFastMapCollisionAttack()
  testBufMapStressAndLeak()
  echo "\n>>> [test_ironclad_map_stress] ALL TESTS PASSED UNCOMPROMISINGLY <<<"
