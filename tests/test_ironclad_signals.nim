## tests/test_ironclad_signals.nim — Ironclad Reactive Engine Verification Suite
##
## Tests:
## 1. Diamond dependency graph (A -> B, A -> C, B + C -> D) glitch-free execution
## 2. Dynamic dependency switching (cond ? A : B) and automatic branch unsubscription
## 3. Nested batch update blocks
## 4. 10,000-cycle stress & zero-leak verification under TrackingAllocator (testWithLeakCheck)
## 5. Chained computed nodes and peek() non-tracking semantics

import corex

echo "================================================================="
echo ">>> RUNNING IRONCLAD SIGNALS REACTIVE ENGINE TEST SUITE <<<"
echo "================================================================="

# =============================================================================
# Test 1: Diamond Dependency Graph (Glitch-Free Verification)
# =============================================================================
block:
  echo "[TEST 1] Diamond Dependency Graph (Glitch-Free Guarantee)..."
  var rt = initReactiveRuntime()

  # Graph structure:
  #       A (Signal)
  #      / \
  #     B   C (Computed)
  #      \ /
  #       D (Computed: B + C)
  #       |
  #     Effect (Observes D)

  let a = rt.createSignal(1)
  let b = rt.createComputed(proc(): int = a.get() * 10)
  let c = rt.createComputed(proc(): int = a.get() * 100)
  let d = rt.createComputed(proc(): int = b.get() + c.get())

  var effectRunCount = 0
  var lastObservedD = 0
  var intermediateGlitches = 0

  let eff = rt.createEffect(proc() =
    inc(effectRunCount)
    let valD = d.get()
    lastObservedD = valD
    let valB = b.get()
    let valC = c.get()
    if valD != valB + valC:
      inc(intermediateGlitches)
  )

  # On creation, effect runs once
  doAssert effectRunCount == 1, "Effect should run once on creation"
  doAssert lastObservedD == 110, "Expected initial D=110, got: " & $lastObservedD
  doAssert intermediateGlitches == 0, "Initial state had glitch!"

  # Now update root signal A: 1 -> 2
  # b becomes 20, c becomes 200, d becomes 220
  a.set(2)

  doAssert effectRunCount == 2, "Glitch detected! Effect ran " & $effectRunCount & " times (expected exactly 2)"
  doAssert lastObservedD == 220, "Expected updated D=220, got: " & $lastObservedD
  doAssert intermediateGlitches == 0, "Intermediate glitch state observed during diamond update!"

  # Update A again: 2 -> 5
  a.set(5)
  doAssert effectRunCount == 3, "Effect should have run exactly 3 times in total"
  doAssert lastObservedD == 550, "Expected updated D=550, got: " & $lastObservedD
  doAssert intermediateGlitches == 0, "Glitch observed on second update!"

  # Setting identical value: no recomputation
  a.set(5)
  doAssert effectRunCount == 3, "Effect should not run when value is unchanged"

  rt.destroy()
  echo "  [PASS] 1. Diamond graph evaluated glitch-free (effect ran exactly 1 time per update)."

# =============================================================================
# Test 2: Dynamic Dependency Switching
# =============================================================================
block:
  echo "[TEST 2] Dynamic Dependency Switching & Automatic Branch Unsubscription..."
  var rt = initReactiveRuntime()

  let cond = rt.createSignal(true)
  let sigA = rt.createSignal(10)
  let sigB = rt.createSignal(20)

  var effectRuns = 0
  var lastResult = 0

  discard rt.createEffect(proc() =
    inc(effectRuns)
    if cond.get():
      lastResult = sigA.get()
    else:
      lastResult = sigB.get()
  )

  # Initial run: cond == true, so depends on cond and sigA
  doAssert effectRuns == 1
  doAssert lastResult == 10

  # Changing sigB (inactive branch) MUST NOT trigger the effect!
  sigB.set(25)
  doAssert effectRuns == 1, "Inactive branch sigB update triggered effect! Unsubscription failed."
  doAssert lastResult == 10

  # Changing sigA (active branch) MUST trigger the effect
  sigA.set(15)
  doAssert effectRuns == 2, "Active branch sigA update did not trigger effect!"
  doAssert lastResult == 15

  # Switch condition to false: now depends on cond and sigB
  cond.set(false)
  doAssert effectRuns == 3
  doAssert lastResult == 25, "Expected lastResult=25 after switching to false branch"

  # Now sigA is the inactive branch! Updating sigA MUST NOT trigger effect!
  sigA.set(99)
  doAssert effectRuns == 3, "Inactive branch sigA update triggered effect! Untracking failed."
  doAssert lastResult == 25

  # Updating sigB (now active branch) MUST trigger effect
  sigB.set(42)
  doAssert effectRuns == 4
  doAssert lastResult == 42

  rt.destroy()
  echo "  [PASS] 2. Dynamic branch switching and unsubscription verified."

# =============================================================================
# Test 3: Nested Batch Blocks
# =============================================================================
block:
  echo "[TEST 3] Nested Batch Update Blocks..."
  var rt = initReactiveRuntime()

  let s1 = rt.createSignal(1)
  let s2 = rt.createSignal(2)
  let s3 = rt.createSignal(3)

  var effectFires = 0
  var sumObserved = 0

  discard rt.createEffect(proc() =
    inc(effectFires)
    sumObserved = s1.get() + s2.get() + s3.get()
  )

  doAssert effectFires == 1
  doAssert sumObserved == 6

  # Nested batch updates: 3 sets inside nested batch scopes
  batch(rt):
    s1.set(10)
    batch(rt):
      s2.set(20)
      batch(rt):
        s3.set(30)
    # Still inside outer batch, effect should not fire yet
    doAssert effectFires == 1, "Effect fired prematurely inside nested batch!"

  # After outer batch ends, effect should fire EXACTLY ONCE
  doAssert effectFires == 2, "Effect should have fired exactly once for batch, fired: " & $effectFires
  doAssert sumObserved == 60, "Expected sum=60, got: " & $sumObserved

  rt.destroy()
  echo "  [PASS] 3. Nested batch updates grouped seamlessly with 1 notification."

# =============================================================================
# Test 4: Chained Computations & Peek Semantics
# =============================================================================
block:
  echo "[TEST 4] Deep Computed Chains & Peek Semantics..."
  var rt = initReactiveRuntime()

  let root = rt.createSignal(1)
  let c1 = rt.createComputed(proc(): int = root.get() + 1)
  let c2 = rt.createComputed(proc(): int = c1.get() * 2)
  let c3 = rt.createComputed(proc(): int = c2.get() + 5)
  let c4 = rt.createComputed(proc(): int = c3.get() * 3)

  # peek should read without tracking
  doAssert root.peek() == 1
  doAssert c4.peek() == ((1 + 1) * 2 + 5) * 3 # (4 + 5) * 3 = 27

  var fires = 0
  var finalVal = 0
  discard rt.createEffect(proc() =
    inc(fires)
    # Reading c4 through .get()
    finalVal = c4.get()
  )

  doAssert fires == 1
  doAssert finalVal == 27

  root.set(2)
  # (2 + 1)*2 = 6, 6 + 5 = 11, 11 * 3 = 33
  doAssert fires == 2
  doAssert finalVal == 33

  rt.destroy()
  echo "  [PASS] 4. Deep chain of 4 computed nodes and peek() verified."

# =============================================================================
# Test 5: 10,000-Cycle Stress & Zero-Leak Verification under TrackingAllocator
# =============================================================================
testWithLeakCheck("signals_10k_lifecycle_leak_audit"):
  echo "[TEST 5] 10,000-Cycle Creation/Update/Dispose Stress & Zero-Leak Audit..."
  var rt = initReactiveRuntime(testAlloc)

  for i in 0 ..< 10_000:
    let s = rt.createSignal(i)
    let c = rt.createComputed(proc(): int = s.get() * 2)
    var effectRan = false
    let e = rt.createEffect(proc() =
      if c.get() >= 0:
        effectRan = true
    )
    doAssert effectRan

    s.set(i + 10)
    doAssert c.get() == (i + 10) * 2

    rt.dispose(e)
    rt.dispose(c)
    rt.dispose(s)

  rt.destroy()
  echo "  [PASS] 5. 10,000 Signal/Computed/Effect lifecycles completed with 0 leaks."

echo "================================================================="
echo ">>> [PASS] ALL IRONCLAD SIGNALS TESTS COMPLETED WITH 100% SUCCESS <<<"
echo "================================================================="
