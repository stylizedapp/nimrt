## corex/concurrency — High-Performance Concurrency & Thread Synchronization
##
## Provides a zero-overhead, memory-safe, cross-platform concurrency toolkit engineered
## for extreme throughput, low latency, and deterministic resource cleanup under ARC/ORC:
##
## - Feature 25: `Atomic[T]` and `MemoryOrder` (Relaxed, Consume, Acquire, Release, AcqRel, SeqCst)
## - Feature 26: `SpinLock` (Value object, TTAS, exponential backoff, hardware `cpuRelax`)
## - Feature 27: `SysLock` (OS mutex: Windows SRWLOCK exclusive, POSIX pthread_mutex_t)
## - Feature 28: `RwLock` (Reader-writer lock: Windows SRWLOCK, POSIX pthread_rwlock_t)
## - Feature 29: RAII Lock Guards (`withLock`, `withReadLock`, `withWriteLock`)
## - Feature 30: `Barrier` (Cyclic rendezvous barrier for N threads with generation counter)
## - Feature 31: `WaitGroup` (Atomic counter coordination primitive with Defect guard)
## - Feature 32: `SpscQueue[T, Cap]` (Lock-free SPSC circular queue with 64-byte cache alignment)
## - Feature 33: `MpmcQueue[T, Cap]` (Dmitry Vyukov bounded MPMC queue with atomic sequence turns)
## - Feature 34: `ThreadPool` & `parallelFor` (OS-condvar parked worker pool with range chunking)

import std/atomics
import std/sysatomics
import std/cpuinfo
import ./adt

export atomics.Atomic, atomics.AtomicFlag, atomics.atomicInc, atomics.atomicDec
export sysatomics.cpuRelax, sysatomics.fence

# =============================================================================
# Platform C Bindings (OS Synchronization Primitives)
# =============================================================================

when defined(windows):
  type
    SRWLockRaw {.importc: "SRWLOCK", header: "<windows.h>", byref.} = object
      p: pointer

    WinCondVar {.importc: "CONDITION_VARIABLE", header: "<windows.h>", byref.} = object
      p: pointer

  proc winInitializeSRWLock(lock: ptr SRWLockRaw) {.
    importc: "InitializeSRWLock", header: "<windows.h>".}
  proc winAcquireSRWLockExclusive(lock: ptr SRWLockRaw) {.
    importc: "AcquireSRWLockExclusive", header: "<windows.h>".}
  proc winTryAcquireSRWLockExclusive(lock: ptr SRWLockRaw): byte {.
    importc: "TryAcquireSRWLockExclusive", header: "<windows.h>".}
  proc winReleaseSRWLockExclusive(lock: ptr SRWLockRaw) {.
    importc: "ReleaseSRWLockExclusive", header: "<windows.h>".}

  proc winAcquireSRWLockShared(lock: ptr SRWLockRaw) {.
    importc: "AcquireSRWLockShared", header: "<windows.h>".}
  proc winTryAcquireSRWLockShared(lock: ptr SRWLockRaw): byte {.
    importc: "TryAcquireSRWLockShared", header: "<windows.h>".}
  proc winReleaseSRWLockShared(lock: ptr SRWLockRaw) {.
    importc: "ReleaseSRWLockShared", header: "<windows.h>".}

  proc winInitializeConditionVariable(cv: ptr WinCondVar) {.
    importc: "InitializeConditionVariable", header: "<windows.h>".}
  proc winWakeConditionVariable(cv: ptr WinCondVar) {.
    importc: "WakeConditionVariable", header: "<windows.h>".}
  proc winWakeAllConditionVariable(cv: ptr WinCondVar) {.
    importc: "WakeAllConditionVariable", header: "<windows.h>".}
  proc winSleepConditionVariableSRW(cv: ptr WinCondVar, lock: ptr SRWLockRaw,
                                    dwMilliseconds: uint32, flags: uint32): byte {.
    importc: "SleepConditionVariableSRW", header: "<windows.h>".}

elif defined(posix):
  type
    PthreadMutexRaw {.importc: "pthread_mutex_t", header: "<pthread.h>", byref.} = object
    PthreadRwlockRaw {.importc: "pthread_rwlock_t", header: "<pthread.h>", byref.} = object
    PthreadCondRaw {.importc: "pthread_cond_t", header: "<pthread.h>", byref.} = object

  proc pthread_mutex_init(m: ptr PthreadMutexRaw, attr: pointer): cint {.
    importc: "pthread_mutex_init", header: "<pthread.h>".}
  proc pthread_mutex_lock(m: ptr PthreadMutexRaw): cint {.
    importc: "pthread_mutex_lock", header: "<pthread.h>".}
  proc pthread_mutex_trylock(m: ptr PthreadMutexRaw): cint {.
    importc: "pthread_mutex_trylock", header: "<pthread.h>".}
  proc pthread_mutex_unlock(m: ptr PthreadMutexRaw): cint {.
    importc: "pthread_mutex_unlock", header: "<pthread.h>".}
  proc pthread_mutex_destroy(m: ptr PthreadMutexRaw): cint {.
    importc: "pthread_mutex_destroy", header: "<pthread.h>".}

  proc pthread_rwlock_init(rw: ptr PthreadRwlockRaw, attr: pointer): cint {.
    importc: "pthread_rwlock_init", header: "<pthread.h>".}
  proc pthread_rwlock_rdlock(rw: ptr PthreadRwlockRaw): cint {.
    importc: "pthread_rwlock_rdlock", header: "<pthread.h>".}
  proc pthread_rwlock_tryrdlock(rw: ptr PthreadRwlockRaw): cint {.
    importc: "pthread_rwlock_tryrdlock", header: "<pthread.h>".}
  proc pthread_rwlock_wrlock(rw: ptr PthreadRwlockRaw): cint {.
    importc: "pthread_rwlock_wrlock", header: "<pthread.h>".}
  proc pthread_rwlock_trywrlock(rw: ptr PthreadRwlockRaw): cint {.
    importc: "pthread_rwlock_trywrlock", header: "<pthread.h>".}
  proc pthread_rwlock_unlock(rw: ptr PthreadRwlockRaw): cint {.
    importc: "pthread_rwlock_unlock", header: "<pthread.h>".}
  proc pthread_rwlock_destroy(rw: ptr PthreadRwlockRaw): cint {.
    importc: "pthread_rwlock_destroy", header: "<pthread.h>".}

  proc pthread_cond_init(cv: ptr PthreadCondRaw, attr: pointer): cint {.
    importc: "pthread_cond_init", header: "<pthread.h>".}
  proc pthread_cond_wait(cv: ptr PthreadCondRaw, m: ptr PthreadMutexRaw): cint {.
    importc: "pthread_cond_wait", header: "<pthread.h>".}
  proc pthread_cond_signal(cv: ptr PthreadCondRaw): cint {.
    importc: "pthread_cond_signal", header: "<pthread.h>".}
  proc pthread_cond_broadcast(cv: ptr PthreadCondRaw): cint {.
    importc: "pthread_cond_broadcast", header: "<pthread.h>".}
  proc pthread_cond_destroy(cv: ptr PthreadCondRaw): cint {.
    importc: "pthread_cond_destroy", header: "<pthread.h>".}

# =============================================================================
# Hardware cpuRelax Intrinsics
# =============================================================================

when defined(vcc):
  proc mm_pause*() {.importc: "_mm_pause", header: "<intrin.h>".}
elif defined(x86) or defined(amd64):
  proc mm_pause*() {.importc: "_mm_pause", header: "<immintrin.h>".}
else:
  proc mm_pause*() {.inline.} = discard

# Note: `cpuRelax*` is re-exported from `std/sysatomics` to prevent symbol
# ambiguity with Nim's implicit `system.cpuRelax`.

# =============================================================================
# Feature 25: `Atomic[T]` and `MemoryOrder`
# =============================================================================

type
  MemoryOrder* = enum
    Relaxed ## No ordering constraints; only atomicity guaranteed.
    Consume ## Data dependency ordering on read operations.
    Acquire ## Barrier: Subsequent reads and writes cannot be reordered before this read.
    Release ## Barrier: Prior reads and writes cannot be reordered after this write.
    AcqRel  ## Barrier: Acts as Acquire on read and Release on write.
    SeqCst  ## Sequentially Consistent: Total global ordering across all threads.

const
  moRelaxed* = MemoryOrder.Relaxed
  moConsume* = MemoryOrder.Consume
  moAcquire* = MemoryOrder.Acquire
  moRelease* = MemoryOrder.Release
  moAcquireRelease* = MemoryOrder.AcqRel
  moAcqRel* = MemoryOrder.AcqRel
  moSequentiallyConsistent* = MemoryOrder.SeqCst
  moSeqCst* = MemoryOrder.SeqCst

template toStd(order: MemoryOrder): atomics.MemoryOrder =
  case order
  of Relaxed: atomics.MemoryOrder.moRelaxed
  of Consume: atomics.MemoryOrder.moConsume
  of Acquire: atomics.MemoryOrder.moAcquire
  of Release: atomics.MemoryOrder.moRelease
  of AcqRel:  atomics.MemoryOrder.moAcquireRelease
  of SeqCst:  atomics.MemoryOrder.moSequentiallyConsistent

func compareExchangeFailureOrder*(order: MemoryOrder): MemoryOrder {.inline.} =
  case order
  of Release: Relaxed
  of AcqRel:  Acquire
  else: order

# Constructors / Initializers
proc initAtomic*[T](val: T): Atomic[T] {.inline.} =
  ## Creates and initializes a new Atomic[T] value.
  result.store(val, moRelaxed)

proc init*[T](location: var Atomic[T], val: T) {.inline.} =
  ## Initializes an existing Atomic[T] location in-place.
  location.store(val, moRelaxed)

# Load Operations
proc load*[T](location: var Atomic[T], order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.load(location, toStd(order))

proc load*[T](location: ptr Atomic[T], order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.load(location[], toStd(order))

# Store Operations
proc store*[T](location: var Atomic[T], desired: T, order: MemoryOrder = SeqCst) {.inline.} =
  atomics.store(location, desired, toStd(order))

proc store*[T](location: ptr Atomic[T], desired: T, order: MemoryOrder = SeqCst) {.inline.} =
  atomics.store(location[], desired, toStd(order))

# Exchange Operations
proc exchange*[T](location: var Atomic[T], desired: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.exchange(location, desired, toStd(order))

proc exchange*[T](location: ptr Atomic[T], desired: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.exchange(location[], desired, toStd(order))

# Compare and Exchange (Strong)
proc compareExchange*[T](location: var Atomic[T], expected: var T, desired: T,
                         success, failure: MemoryOrder): bool {.inline.} =
  atomics.compareExchange(location, expected, desired, toStd(success), toStd(failure))

proc compareExchange*[T](location: var Atomic[T], expected: T, desired: T,
                         success, failure: MemoryOrder): bool {.inline.} =
  var exp = expected
  atomics.compareExchange(location, exp, desired, toStd(success), toStd(failure))

proc compareExchange*[T](location: var Atomic[T], expected: var T, desired: T,
                         order: MemoryOrder = SeqCst): bool {.inline.} =
  compareExchange(location, expected, desired, order, compareExchangeFailureOrder(order))

proc compareExchange*[T](location: var Atomic[T], expected: T, desired: T,
                         order: MemoryOrder = SeqCst): bool {.inline.} =
  var exp = expected
  compareExchange(location, exp, desired, order, compareExchangeFailureOrder(order))

proc compareExchange*[T](location: ptr Atomic[T], expected: var T, desired: T,
                         success, failure: MemoryOrder): bool {.inline.} =
  compareExchange(location[], expected, desired, success, failure)

proc compareExchange*[T](location: ptr Atomic[T], expected: T, desired: T,
                         success, failure: MemoryOrder): bool {.inline.} =
  compareExchange(location[], expected, desired, success, failure)

proc compareExchange*[T](location: ptr Atomic[T], expected: var T, desired: T,
                         order: MemoryOrder = SeqCst): bool {.inline.} =
  compareExchange(location[], expected, desired, order)

proc compareExchange*[T](location: ptr Atomic[T], expected: T, desired: T,
                         order: MemoryOrder = SeqCst): bool {.inline.} =
  compareExchange(location[], expected, desired, order)

# Compare and Exchange (Weak)
proc compareExchangeWeak*[T](location: var Atomic[T], expected: var T, desired: T,
                             success, failure: MemoryOrder): bool {.inline.} =
  atomics.compareExchangeWeak(location, expected, desired, toStd(success), toStd(failure))

proc compareExchangeWeak*[T](location: var Atomic[T], expected: T, desired: T,
                             success, failure: MemoryOrder): bool {.inline.} =
  var exp = expected
  atomics.compareExchangeWeak(location, exp, desired, toStd(success), toStd(failure))

proc compareExchangeWeak*[T](location: var Atomic[T], expected: var T, desired: T,
                             order: MemoryOrder = SeqCst): bool {.inline.} =
  compareExchangeWeak(location, expected, desired, order, compareExchangeFailureOrder(order))

proc compareExchangeWeak*[T](location: var Atomic[T], expected: T, desired: T,
                             order: MemoryOrder = SeqCst): bool {.inline.} =
  var exp = expected
  compareExchangeWeak(location, exp, desired, order, compareExchangeFailureOrder(order))

proc compareExchangeWeak*[T](location: ptr Atomic[T], expected: var T, desired: T,
                             success, failure: MemoryOrder): bool {.inline.} =
  compareExchangeWeak(location[], expected, desired, success, failure)

proc compareExchangeWeak*[T](location: ptr Atomic[T], expected: T, desired: T,
                             success, failure: MemoryOrder): bool {.inline.} =
  compareExchangeWeak(location[], expected, desired, success, failure)

proc compareExchangeWeak*[T](location: ptr Atomic[T], expected: var T, desired: T,
                             order: MemoryOrder = SeqCst): bool {.inline.} =
  compareExchangeWeak(location[], expected, desired, order)

proc compareExchangeWeak*[T](location: ptr Atomic[T], expected: T, desired: T,
                             order: MemoryOrder = SeqCst): bool {.inline.} =
  compareExchangeWeak(location[], expected, desired, order)

# Arithmetic: fetchAdd & fetchSub
proc fetchAdd*[T: SomeInteger](location: var Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.fetchAdd(location, value, toStd(order))

proc fetchAdd*[T: SomeInteger](location: ptr Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  fetchAdd(location[], value, order)

proc fetchSub*[T: SomeInteger](location: var Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.fetchSub(location, value, toStd(order))

proc fetchSub*[T: SomeInteger](location: ptr Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  fetchSub(location[], value, order)

# Pointer Arithmetic CAS overloads
proc fetchAdd*[T](location: var Atomic[ptr T], offset: int, order: MemoryOrder = SeqCst): ptr T =
  var cur = location.load(Relaxed)
  while true:
    let next = cast[ptr T](cast[uint](cur) + cast[uint](offset * sizeof(T)))
    if location.compareExchangeWeak(cur, next, order, compareExchangeFailureOrder(order)):
      return cur

proc fetchAdd*[T](location: ptr Atomic[ptr T], offset: int, order: MemoryOrder = SeqCst): ptr T {.inline.} =
  fetchAdd(location[], offset, order)

proc fetchSub*[T](location: var Atomic[ptr T], offset: int, order: MemoryOrder = SeqCst): ptr T =
  fetchAdd(location, -offset, order)

proc fetchSub*[T](location: ptr Atomic[ptr T], offset: int, order: MemoryOrder = SeqCst): ptr T {.inline.} =
  fetchSub(location[], offset, order)

proc fetchAdd*(location: var Atomic[pointer], offset: int, order: MemoryOrder = SeqCst): pointer =
  var cur = location.load(Relaxed)
  while true:
    let next = cast[pointer](cast[uint](cur) + cast[uint](offset))
    if location.compareExchangeWeak(cur, next, order, compareExchangeFailureOrder(order)):
      return cur

proc fetchAdd*(location: ptr Atomic[pointer], offset: int, order: MemoryOrder = SeqCst): pointer {.inline.} =
  fetchAdd(location[], offset, order)

proc fetchSub*(location: var Atomic[pointer], offset: int, order: MemoryOrder = SeqCst): pointer =
  fetchAdd(location, -offset, order)

proc fetchSub*(location: ptr Atomic[pointer], offset: int, order: MemoryOrder = SeqCst): pointer {.inline.} =
  fetchSub(location[], offset, order)

# Bitwise Operations: fetchAnd, fetchOr, fetchXor
proc fetchAnd*[T: SomeInteger](location: var Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.fetchAnd(location, value, toStd(order))

proc fetchAnd*[T: SomeInteger](location: ptr Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  fetchAnd(location[], value, order)

proc fetchOr*[T: SomeInteger](location: var Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.fetchOr(location, value, toStd(order))

proc fetchOr*[T: SomeInteger](location: ptr Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  fetchOr(location[], value, order)

proc fetchXor*[T: SomeInteger](location: var Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.fetchXor(location, value, toStd(order))

proc fetchXor*[T: SomeInteger](location: ptr Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  fetchXor(location[], value, order)

proc fetchAnd*(location: var Atomic[bool], value: bool, order: MemoryOrder = SeqCst): bool =
  var cur = location.load(Relaxed)
  while true:
    let next = cur and value
    if location.compareExchangeWeak(cur, next, order, compareExchangeFailureOrder(order)):
      return cur

proc fetchAnd*(location: ptr Atomic[bool], value: bool, order: MemoryOrder = SeqCst): bool {.inline.} =
  fetchAnd(location[], value, order)

proc fetchOr*(location: var Atomic[bool], value: bool, order: MemoryOrder = SeqCst): bool =
  var cur = location.load(Relaxed)
  while true:
    let next = cur or value
    if location.compareExchangeWeak(cur, next, order, compareExchangeFailureOrder(order)):
      return cur

proc fetchOr*(location: ptr Atomic[bool], value: bool, order: MemoryOrder = SeqCst): bool {.inline.} =
  fetchOr(location[], value, order)

proc fetchXor*(location: var Atomic[bool], value: bool, order: MemoryOrder = SeqCst): bool =
  var cur = location.load(Relaxed)
  while true:
    let next = cur != value
    if location.compareExchangeWeak(cur, next, order, compareExchangeFailureOrder(order)):
      return cur

proc fetchXor*(location: ptr Atomic[bool], value: bool, order: MemoryOrder = SeqCst): bool {.inline.} =
  fetchXor(location[], value, order)

# Arithmetic Ergonomics & Fences
proc atomicInc*[T: SomeInteger](location: ptr Atomic[T], value: T = 1) {.inline.} =
  atomicInc(location[], value)

proc atomicDec*[T: SomeInteger](location: ptr Atomic[T], value: T = 1) {.inline.} =
  atomicDec(location[], value)

proc `+=`*[T: SomeInteger](location: var Atomic[T], value: T) {.inline.} =
  atomicInc(location, value)

proc `+=`*[T: SomeInteger](location: ptr Atomic[T], value: T) {.inline.} =
  atomicInc(location[], value)

proc `-=`*[T: SomeInteger](location: var Atomic[T], value: T) {.inline.} =
  atomicDec(location, value)

proc `-=`*[T: SomeInteger](location: ptr Atomic[T], value: T) {.inline.} =
  atomicDec(location[], value)

proc fence*(order: MemoryOrder) {.inline.} =
  ## Inserts a hardware memory barrier instruction.
  atomics.fence(toStd(order))

proc signalFence*(order: MemoryOrder = SeqCst) {.inline.} =
  ## Inserts a compiler reordering barrier without emitting hardware instructions.
  atomics.signalFence(toStd(order))

# =============================================================================
# Feature 26: `SpinLock` (TTAS with Exponential Backoff)
# =============================================================================

type
  SpinLock* = object
    ## User-space spinlock utilizing Test-and-Test-and-Set (TTAS) and hardware cpuRelax.
    ## Footprint: 1 byte, pure value object, zero heap allocations.
    state: Atomic[bool]

proc initSpinLock*(): SpinLock {.inline.} =
  ## Creates and initializes an unlocked SpinLock.
  result.state.store(false, moRelaxed)

proc initSpinLock*(lock: var SpinLock) {.inline.} =
  ## Initializes an existing SpinLock in-place.
  lock.state.store(false, moRelaxed)

proc tryAcquire*(lock: var SpinLock): bool {.inline.} =
  ## Attempts to acquire the spinlock without spinning. Returns true if acquired.
  not lock.state.load(moRelaxed) and not lock.state.exchange(true, moAcquire)

proc tryAcquire*(lock: ptr SpinLock): bool {.inline.} =
  tryAcquire(lock[])

proc acquire*(lock: var SpinLock) {.inline.} =
  ## Acquires the spinlock, executing TTAS spin-wait with exponential pause backoff.
  var backoff = 1
  const maxBackoff = 64
  while true:
    # 1. Fast path: optimistic attempt
    if not lock.state.exchange(true, moAcquire):
      return

    # 2. Contention path: spin locally in L1/L2 cache using relaxed reads
    while lock.state.load(moRelaxed):
      for _ in 0 ..< backoff:
        cpuRelax()
      if backoff < maxBackoff:
        backoff = backoff shl 1

proc acquire*(lock: ptr SpinLock) {.inline.} =
  acquire(lock[])

proc release*(lock: var SpinLock) {.inline.} =
  ## Releases ownership of the spinlock.
  lock.state.store(false, moRelease)

proc release*(lock: ptr SpinLock) {.inline.} =
  release(lock[])

# =============================================================================
# Feature 27: `SysLock` (OS Mutex)
# =============================================================================

type
  SysLock* = object
    ## Lightweight OS mutex:
    ## - Windows: Slim Reader/Writer Lock (SRWLOCK) in exclusive mode (8 bytes, zero heap allocations).
    ## - POSIX: pthread_mutex_t.
    when defined(windows):
      raw: SRWLockRaw
    elif defined(posix):
      raw: PthreadMutexRaw
    else:
      raw: pointer

proc `=copy`*(dest: var SysLock, src: SysLock) {.
  error: "SysLock is an OS synchronization primitive and cannot be copied; pass by pointer or var reference".}

proc initSysLock*(): SysLock {.inline.} =
  ## Creates and initializes a new SysLock.
  when defined(windows):
    winInitializeSRWLock(addr result.raw)
  elif defined(posix):
    discard pthread_mutex_init(addr result.raw, nil)

proc initSysLock*(lock: var SysLock) {.inline.} =
  ## Initializes an existing SysLock in-place.
  when defined(windows):
    winInitializeSRWLock(addr lock.raw)
  elif defined(posix):
    discard pthread_mutex_init(addr lock.raw, nil)

proc acquire*(lock: var SysLock) {.inline.} =
  ## Acquires exclusive ownership of the OS mutex, blocking until acquired.
  when defined(windows):
    winAcquireSRWLockExclusive(addr lock.raw)
  elif defined(posix):
    discard pthread_mutex_lock(addr lock.raw)

proc acquire*(lock: ptr SysLock) {.inline.} =
  acquire(lock[])

proc tryAcquire*(lock: var SysLock): bool {.inline.} =
  ## Attempts to acquire exclusive ownership without blocking.
  when defined(windows):
    result = winTryAcquireSRWLockExclusive(addr lock.raw) != 0'u8
  elif defined(posix):
    result = pthread_mutex_trylock(addr lock.raw) == 0

proc tryAcquire*(lock: ptr SysLock): bool {.inline.} =
  tryAcquire(lock[])

proc release*(lock: var SysLock) {.inline.} =
  ## Releases exclusive ownership of the OS mutex.
  when defined(windows):
    winReleaseSRWLockExclusive(addr lock.raw)
  elif defined(posix):
    discard pthread_mutex_unlock(addr lock.raw)

proc release*(lock: ptr SysLock) {.inline.} =
  release(lock[])

proc deinitSysLock*(lock: var SysLock) {.inline.} =
  ## Releases system resources associated with the lock on POSIX (no-op on Windows SRWLock).
  when defined(posix):
    discard pthread_mutex_destroy(addr lock.raw)

proc deinitSysLock*(lock: ptr SysLock) {.inline.} =
  deinitSysLock(lock[])

# =============================================================================
# Feature 28: `RwLock` (Reader-Writer Lock)
# =============================================================================

type
  RwLock* = object
    ## Cross-platform Reader-Writer Lock:
    ## - Allows multiple concurrent readers (shared mode).
    ## - Allows a single exclusive writer.
    ## - Windows: SRWLOCK shared & exclusive modes (8 bytes, zero heap allocations).
    ## - POSIX: pthread_rwlock_t.
    when defined(windows):
      raw: SRWLockRaw
    elif defined(posix):
      raw: PthreadRwlockRaw
    else:
      raw: pointer

proc `=copy`*(dest: var RwLock, src: RwLock) {.
  error: "RwLock is an OS synchronization primitive and cannot be copied; pass by pointer or var reference".}

proc initRwLock*(): RwLock {.inline.} =
  ## Initializes a new RwLock.
  when defined(windows):
    winInitializeSRWLock(addr result.raw)
  elif defined(posix):
    discard pthread_rwlock_init(addr result.raw, nil)

proc initRwLock*(lock: var RwLock) {.inline.} =
  ## Initializes an existing RwLock in-place.
  when defined(windows):
    winInitializeSRWLock(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_init(addr lock.raw, nil)

# Read operations
proc acquireRead*(lock: var RwLock) {.inline.} =
  ## Acquires shared read access on the lock, blocking until acquired.
  when defined(windows):
    winAcquireSRWLockShared(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_rdlock(addr lock.raw)

proc acquireRead*(lock: ptr RwLock) {.inline.} =
  acquireRead(lock[])

proc tryAcquireRead*(lock: var RwLock): bool {.inline.} =
  ## Attempts to acquire shared read access without blocking.
  when defined(windows):
    result = winTryAcquireSRWLockShared(addr lock.raw) != 0'u8
  elif defined(posix):
    result = pthread_rwlock_tryrdlock(addr lock.raw) == 0

proc tryAcquireRead*(lock: ptr RwLock): bool {.inline.} =
  tryAcquireRead(lock[])

proc releaseRead*(lock: var RwLock) {.inline.} =
  ## Releases shared read access on the lock.
  when defined(windows):
    winReleaseSRWLockShared(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_unlock(addr lock.raw)

proc releaseRead*(lock: ptr RwLock) {.inline.} =
  releaseRead(lock[])

# Write operations
proc acquireWrite*(lock: var RwLock) {.inline.} =
  ## Acquires exclusive write access on the lock, blocking until acquired.
  when defined(windows):
    winAcquireSRWLockExclusive(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_wrlock(addr lock.raw)

proc acquireWrite*(lock: ptr RwLock) {.inline.} =
  acquireWrite(lock[])

proc tryAcquireWrite*(lock: var RwLock): bool {.inline.} =
  ## Attempts to acquire exclusive write access without blocking.
  when defined(windows):
    result = winTryAcquireSRWLockExclusive(addr lock.raw) != 0'u8
  elif defined(posix):
    result = pthread_rwlock_trywrlock(addr lock.raw) == 0

proc tryAcquireWrite*(lock: ptr RwLock): bool {.inline.} =
  tryAcquireWrite(lock[])

proc releaseWrite*(lock: var RwLock) {.inline.} =
  ## Releases exclusive write access on the lock.
  when defined(windows):
    winReleaseSRWLockExclusive(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_unlock(addr lock.raw)

proc releaseWrite*(lock: ptr RwLock) {.inline.} =
  releaseWrite(lock[])

# Exclusive Lock Aliases (RwLock conforms to generic Lock interface)
proc acquire*(lock: var RwLock) {.inline.} = acquireWrite(lock)
proc acquire*(lock: ptr RwLock) {.inline.} = acquireWrite(lock[])
proc tryAcquire*(lock: var RwLock): bool {.inline.} = tryAcquireWrite(lock)
proc tryAcquire*(lock: ptr RwLock): bool {.inline.} = tryAcquireWrite(lock[])
proc release*(lock: var RwLock) {.inline.} = releaseWrite(lock)
proc release*(lock: ptr RwLock) {.inline.} = releaseWrite(lock[])

proc deinitRwLock*(lock: var RwLock) {.inline.} =
  ## Releases system resources associated with the RwLock on POSIX (no-op on Windows).
  when defined(posix):
    discard pthread_rwlock_destroy(addr lock.raw)

proc deinitRwLock*(lock: ptr RwLock) {.inline.} =
  deinitRwLock(lock[])

# =============================================================================
# Feature 29: RAII Lock Guards
# =============================================================================

template withLock*(lock: untyped, body: untyped): untyped =
  ## Scoped lock guard: Acquires the given lock (SysLock, SpinLock, or RwLock for writing),
  ## executes the body, and guarantees release in a `finally` block even under exceptions
  ## or early returns.
  acquire(lock)
  try:
    body
  finally:
    release(lock)

template withReadLock*(lock: untyped, body: untyped): untyped =
  ## Scoped read guard: Acquires shared read access on an RwLock, executes the body,
  ## and guarantees release via `finally`.
  acquireRead(lock)
  try:
    body
  finally:
    releaseRead(lock)

template withWriteLock*(lock: untyped, body: untyped): untyped =
  ## Scoped write guard: Acquires exclusive write access on an RwLock, executes the body,
  ## and guarantees release via `finally`.
  acquireWrite(lock)
  try:
    body
  finally:
    releaseWrite(lock)

# =============================================================================
# Feature 30: `Barrier` (Cyclic Rendezvous Barrier)
# =============================================================================

type
  Barrier* = object
    ## Reusable rendezvous synchronization barrier for N threads across algorithmic phases.
    ## Sleeping threads consume 0% CPU on OS condition variables.
    partiesNum: int
    countNum: int
    generation: int
    when defined(windows):
      lock: SRWLockRaw
      cond: WinCondVar
    elif defined(posix):
      lock: PthreadMutexRaw
      cond: PthreadCondRaw

proc `=copy`*(dest: var Barrier, src: Barrier) {.
  error: "Barrier is a thread coordination primitive and cannot be copied; pass by pointer or var reference".}

proc initBarrier*(parties: int): Barrier =
  ## Creates and initializes a cyclic Barrier for the given number of participating threads.
  if parties <= 0:
    raise newException(ValueError, "Barrier parties must be positive")
  result.partiesNum = parties
  result.countNum = parties
  result.generation = 0
  when defined(windows):
    winInitializeSRWLock(addr result.lock)
    winInitializeConditionVariable(addr result.cond)
  elif defined(posix):
    discard pthread_mutex_init(addr result.lock, nil)
    discard pthread_cond_init(addr result.cond, nil)

proc initBarrier*(b: var Barrier, parties: int) =
  ## Initializes an existing Barrier in-place.
  if parties <= 0:
    raise newException(ValueError, "Barrier parties must be positive")
  b.partiesNum = parties
  b.countNum = parties
  b.generation = 0
  when defined(windows):
    winInitializeSRWLock(addr b.lock)
    winInitializeConditionVariable(addr b.cond)
  elif defined(posix):
    discard pthread_mutex_init(addr b.lock, nil)
    discard pthread_cond_init(addr b.cond, nil)

proc wait*(b: var Barrier): bool {.discardable.} =
  ## Waits until all parties have arrived at the barrier.
  ## Returns true for exactly one thread per cycle (the trip leader), and false for all others.
  when defined(windows):
    winAcquireSRWLockExclusive(addr b.lock)
    let gen = b.generation
    dec(b.countNum)
    if b.countNum == 0:
      inc(b.generation)
      b.countNum = b.partiesNum
      winWakeAllConditionVariable(addr b.cond)
      winReleaseSRWLockExclusive(addr b.lock)
      return true
    else:
      while b.generation == gen:
        discard winSleepConditionVariableSRW(addr b.cond, addr b.lock, 0xFFFFFFFF'u32, 0'u32)
      winReleaseSRWLockExclusive(addr b.lock)
      return false
  elif defined(posix):
    discard pthread_mutex_lock(addr b.lock)
    let gen = b.generation
    dec(b.countNum)
    if b.countNum == 0:
      inc(b.generation)
      b.countNum = b.partiesNum
      discard pthread_cond_broadcast(addr b.cond)
      discard pthread_mutex_unlock(addr b.lock)
      return true
    else:
      while b.generation == gen:
        discard pthread_cond_wait(addr b.cond, addr b.lock)
      discard pthread_mutex_unlock(addr b.lock)
      return false

proc wait*(b: ptr Barrier): bool {.discardable, inline.} =
  wait(b[])

proc parties*(b: Barrier): int {.inline.} =
  b.partiesNum

proc parties*(b: ptr Barrier): int {.inline.} =
  b[].partiesNum

proc count*(b: var Barrier): int =
  when defined(windows):
    winAcquireSRWLockExclusive(addr b.lock)
    result = b.countNum
    winReleaseSRWLockExclusive(addr b.lock)
  elif defined(posix):
    discard pthread_mutex_lock(addr b.lock)
    result = b.countNum
    discard pthread_mutex_unlock(addr b.lock)

proc count*(b: ptr Barrier): int {.inline.} =
  count(b[])

proc reset*(b: var Barrier) =
  ## Resets the barrier to its initial state, waking any waiting threads and advancing phase.
  when defined(windows):
    winAcquireSRWLockExclusive(addr b.lock)
    b.countNum = b.partiesNum
    inc(b.generation)
    winWakeAllConditionVariable(addr b.cond)
    winReleaseSRWLockExclusive(addr b.lock)
  elif defined(posix):
    discard pthread_mutex_lock(addr b.lock)
    b.countNum = b.partiesNum
    inc(b.generation)
    discard pthread_cond_broadcast(addr b.cond)
    discard pthread_mutex_unlock(addr b.lock)

proc reset*(b: ptr Barrier) {.inline.} =
  reset(b[])

# =============================================================================
# Feature 31: `WaitGroup` (Atomic Counter Coordination)
# =============================================================================

type
  WaitGroup* = object
    ## Coordinates batches of worker threads via an atomic counter.
    ## Sleeping waiters park on OS condition variables at 0% idle CPU.
    counter: int
    when defined(windows):
      lock: SRWLockRaw
      cond: WinCondVar
    elif defined(posix):
      lock: PthreadMutexRaw
      cond: PthreadCondRaw

proc `=copy`*(dest: var WaitGroup, src: WaitGroup) {.
  error: "WaitGroup is a thread coordination primitive and cannot be copied; pass by pointer or var reference".}

proc initWaitGroup*(): WaitGroup =
  ## Initializes a new WaitGroup with a counter of 0.
  result.counter = 0
  when defined(windows):
    winInitializeSRWLock(addr result.lock)
    winInitializeConditionVariable(addr result.cond)
  elif defined(posix):
    discard pthread_mutex_init(addr result.lock, nil)
    discard pthread_cond_init(addr result.cond, nil)

proc initWaitGroup*(wg: var WaitGroup) =
  ## Initializes an existing WaitGroup in-place with a counter of 0.
  wg.counter = 0
  when defined(windows):
    winInitializeSRWLock(addr wg.lock)
    winInitializeConditionVariable(addr wg.cond)
  elif defined(posix):
    discard pthread_mutex_init(addr wg.lock, nil)
    discard pthread_cond_init(addr wg.cond, nil)

proc add*(wg: var WaitGroup, delta: int = 1) =
  ## Increments or decrements the WaitGroup counter by delta.
  ## Raises Defect if the counter becomes negative.
  when defined(windows):
    winAcquireSRWLockExclusive(addr wg.lock)
    wg.counter += delta
    if wg.counter < 0:
      winReleaseSRWLockExclusive(addr wg.lock)
      raise newException(Defect, "negative WaitGroup counter")
    if wg.counter == 0:
      winWakeAllConditionVariable(addr wg.cond)
    winReleaseSRWLockExclusive(addr wg.lock)
  elif defined(posix):
    discard pthread_mutex_lock(addr wg.lock)
    wg.counter += delta
    if wg.counter < 0:
      discard pthread_mutex_unlock(addr wg.lock)
      raise newException(Defect, "negative WaitGroup counter")
    if wg.counter == 0:
      discard pthread_cond_broadcast(addr wg.cond)
    discard pthread_mutex_unlock(addr wg.lock)

proc add*(wg: ptr WaitGroup, delta: int = 1) {.inline.} =
  add(wg[], delta)

proc done*(wg: var WaitGroup) {.inline.} =
  ## Decrements the WaitGroup counter by 1.
  wg.add(-1)

proc done*(wg: ptr WaitGroup) {.inline.} =
  done(wg[])

proc wait*(wg: var WaitGroup) =
  ## Blocks until the WaitGroup counter reaches 0.
  when defined(windows):
    winAcquireSRWLockExclusive(addr wg.lock)
    while wg.counter > 0:
      discard winSleepConditionVariableSRW(addr wg.cond, addr wg.lock, 0xFFFFFFFF'u32, 0'u32)
    winReleaseSRWLockExclusive(addr wg.lock)
  elif defined(posix):
    discard pthread_mutex_lock(addr wg.lock)
    while wg.counter > 0:
      discard pthread_cond_wait(addr wg.cond, addr wg.lock)
    discard pthread_mutex_unlock(addr wg.lock)

proc wait*(wg: ptr WaitGroup) {.inline.} =
  wait(wg[])

proc value*(wg: WaitGroup): int {.inline.} =
  wg.counter

proc value*(wg: var WaitGroup): int {.inline.} =
  wg.counter

proc value*(wg: ptr WaitGroup): int {.inline.} =
  wg[].counter

# =============================================================================
# Feature 32: `SpscQueue[T; Cap: static int]` (Lock-Free SPSC Circular Queue)
# =============================================================================

const CacheLineSize = 64

type
  SpscQueue*[T; Cap: static int] = object
    ## Lock-free Single-Producer Single-Consumer circular queue.
    ## Features:
    ## - 64-byte cache line alignment on tail, head, and buffer (zero false sharing).
    ## - Power-of-two bitmask indexing.
    ## - Cached head/tail optimization minimizing inter-core interconnect traffic.
    ## - Zero steady-state allocations and move semantics.
    tail {.align: CacheLineSize.}: Atomic[uint64]
    cachedHead: uint64
    pad1: array[CacheLineSize - sizeof(Atomic[uint64]) - sizeof(uint64), byte]

    head {.align: CacheLineSize.}: Atomic[uint64]
    cachedTail: uint64
    pad2: array[CacheLineSize - sizeof(Atomic[uint64]) - sizeof(uint64), byte]

    buffer {.align: CacheLineSize.}: array[Cap, T]

proc `=copy`*[T; Cap: static int](dest: var SpscQueue[T, Cap], src: SpscQueue[T, Cap]) {.
  error: "SpscQueue cannot be copied; pass by pointer or var reference".}

proc initSpscQueue*[T; Cap: static int](): SpscQueue[T, Cap] =
  ## Initializes a new SpscQueue. Capacity Cap must be a power of two and >= 2.
  when (Cap and (Cap - 1)) != 0 or Cap < 2:
    {.error: "SpscQueue Cap must be a power of two and >= 2".}
  result.tail.store(0'u64, moRelaxed)
  result.head.store(0'u64, moRelaxed)
  result.cachedHead = 0
  result.cachedTail = 0

proc initSpscQueue*[T; Cap: static int](q: var SpscQueue[T, Cap]) =
  ## Initializes an existing SpscQueue in-place.
  when (Cap and (Cap - 1)) != 0 or Cap < 2:
    {.error: "SpscQueue Cap must be a power of two and >= 2".}
  q.tail.store(0'u64, moRelaxed)
  q.head.store(0'u64, moRelaxed)
  q.cachedHead = 0
  q.cachedTail = 0

proc newSpscQueue*[T; Cap: static int](): ptr SpscQueue[T, Cap] =
  ## Allocates and initializes an SpscQueue on the shared heap.
  result = cast[ptr SpscQueue[T, Cap]](allocShared0(sizeof(SpscQueue[T, Cap])))
  initSpscQueue(result[])

proc push*[T; Cap: static int](q: var SpscQueue[T, Cap], val: sink T): bool =
  ## Pushes an element into the queue from the producer thread.
  ## Returns true if pushed, or false if the queue is full.
  const Mask = uint64(Cap - 1)
  let currentTail = q.tail.load(moRelaxed)
  if currentTail - q.cachedHead >= uint64(Cap):
    q.cachedHead = q.head.load(moAcquire)
    if currentTail - q.cachedHead >= uint64(Cap):
      return false # Queue is full
  q.buffer[int(currentTail and Mask)] = val
  q.tail.store(currentTail + 1, moRelease)
  return true

proc push*[T; Cap: static int](q: ptr SpscQueue[T, Cap], val: sink T): bool {.inline.} =
  push(q[], val)

proc pop*[T; Cap: static int](q: var SpscQueue[T, Cap], val: var T): bool =
  ## Pops an element from the queue into `val` from the consumer thread.
  ## Returns true if popped, or false if the queue is empty.
  const Mask = uint64(Cap - 1)
  let currentHead = q.head.load(moRelaxed)
  if currentHead == q.cachedTail:
    q.cachedTail = q.tail.load(moAcquire)
    if currentHead == q.cachedTail:
      return false # Queue is empty
  val = move(q.buffer[int(currentHead and Mask)])
  q.head.store(currentHead + 1, moRelease)
  return true

proc pop*[T; Cap: static int](q: ptr SpscQueue[T, Cap], val: var T): bool {.inline.} =
  pop(q[], val)

proc pop*[T; Cap: static int](q: var SpscQueue[T, Cap]): Option[T] =
  ## Ergonomic Option pop: Returns Some(item) or None.
  var val: T
  if q.pop(val):
    result = some(val)
  else:
    result = none(T)

proc pop*[T; Cap: static int](q: ptr SpscQueue[T, Cap]): Option[T] {.inline.} =
  pop(q[])

proc len*[T; Cap: static int](q: var SpscQueue[T, Cap]): int {.inline.} =
  ## Returns the approximate number of elements currently queued.
  let t = q.tail.load(moAcquire)
  let h = q.head.load(moAcquire)
  let diff = t - h
  if diff > uint64(Cap):
    result = 0
  else:
    result = int(diff)

proc len*[T; Cap: static int](q: SpscQueue[T, Cap]): int {.inline.} =
  let t = q.tail.load(moAcquire)
  let h = q.head.load(moAcquire)
  let diff = t - h
  if diff > uint64(Cap):
    result = 0
  else:
    result = int(diff)

proc len*[T; Cap: static int](q: ptr SpscQueue[T, Cap]): int {.inline.} =
  len(q[])

proc empty*[T; Cap: static int](q: var SpscQueue[T, Cap]): bool {.inline.} =
  q.len == 0

proc empty*[T; Cap: static int](q: SpscQueue[T, Cap]): bool {.inline.} =
  q.len == 0

proc empty*[T; Cap: static int](q: ptr SpscQueue[T, Cap]): bool {.inline.} =
  q[].empty

proc full*[T; Cap: static int](q: var SpscQueue[T, Cap]): bool {.inline.} =
  q.len >= Cap

proc full*[T; Cap: static int](q: SpscQueue[T, Cap]): bool {.inline.} =
  q.len >= Cap

proc full*[T; Cap: static int](q: ptr SpscQueue[T, Cap]): bool {.inline.} =
  q[].full

# =============================================================================
# Feature 33: `MpmcQueue[T; Cap: static int]` (Vyukov Bounded MPMC Queue)
# =============================================================================

type
  MpmcCell[T] = object
    sequence: Atomic[uint64]
    data: T

  MpmcQueue*[T; Cap: static int] = object
    ## Dmitry Vyukov's lock-free bounded Multi-Producer Multi-Consumer ring buffer.
    ## Uses per-cell atomic sequence turns and modular wrap-around arithmetic.
    enqueuePos {.align: CacheLineSize.}: Atomic[uint64]
    pad1: array[CacheLineSize - sizeof(Atomic[uint64]), byte]

    dequeuePos {.align: CacheLineSize.}: Atomic[uint64]
    pad2: array[CacheLineSize - sizeof(Atomic[uint64]), byte]

    cells {.align: CacheLineSize.}: array[Cap, MpmcCell[T]]

proc `=copy`*[T; Cap: static int](dest: var MpmcQueue[T, Cap], src: MpmcQueue[T, Cap]) {.
  error: "MpmcQueue cannot be copied; pass by pointer or var reference".}

proc initMpmcQueue*[T; Cap: static int](): MpmcQueue[T, Cap] =
  ## Initializes a new MpmcQueue. Capacity Cap must be a power of two and >= 2.
  when (Cap and (Cap - 1)) != 0 or Cap < 2:
    {.error: "MpmcQueue Cap must be a power of two and >= 2".}
  result.enqueuePos.store(0'u64, moRelaxed)
  result.dequeuePos.store(0'u64, moRelaxed)
  for i in 0 ..< Cap:
    result.cells[i].sequence.store(uint64(i), moRelaxed)

proc initMpmcQueue*[T; Cap: static int](q: var MpmcQueue[T, Cap]) =
  ## Initializes an existing MpmcQueue in-place.
  when (Cap and (Cap - 1)) != 0 or Cap < 2:
    {.error: "MpmcQueue Cap must be a power of two and >= 2".}
  q.enqueuePos.store(0'u64, moRelaxed)
  q.dequeuePos.store(0'u64, moRelaxed)
  for i in 0 ..< Cap:
    q.cells[i].sequence.store(uint64(i), moRelaxed)

proc newMpmcQueue*[T; Cap: static int](): ptr MpmcQueue[T, Cap] =
  ## Allocates and initializes an MpmcQueue on the shared heap.
  result = cast[ptr MpmcQueue[T, Cap]](allocShared0(sizeof(MpmcQueue[T, Cap])))
  initMpmcQueue(result[])

proc push*[T; Cap: static int](q: var MpmcQueue[T, Cap], val: sink T): bool =
  ## Atomically pushes an element into the MPMC queue.
  ## Returns true if pushed, or false if the queue is full.
  const Mask = uint64(Cap - 1)
  var pos = q.enqueuePos.load(moRelaxed)
  while true:
    let cell = addr q.cells[int(pos and Mask)]
    let seq = cell.sequence.load(moAcquire)
    let dif = cast[int64](seq - pos)
    if dif == 0:
      if q.enqueuePos.compareExchange(pos, pos + 1, moRelaxed, moRelaxed):
        cell.data = val
        cell.sequence.store(pos + 1, moRelease)
        return true
    elif dif < 0:
      return false # Queue is full
    else:
      pos = q.enqueuePos.load(moRelaxed)

proc push*[T; Cap: static int](q: ptr MpmcQueue[T, Cap], val: sink T): bool {.inline.} =
  push(q[], val)

proc pop*[T; Cap: static int](q: var MpmcQueue[T, Cap], val: var T): bool =
  ## Atomically pops an element from the MPMC queue into `val`.
  ## Returns true if popped, or false if the queue is empty.
  const Mask = uint64(Cap - 1)
  var pos = q.dequeuePos.load(moRelaxed)
  while true:
    let cell = addr q.cells[int(pos and Mask)]
    let seq = cell.sequence.load(moAcquire)
    let dif = cast[int64](seq - (pos + 1))
    if dif == 0:
      if q.dequeuePos.compareExchange(pos, pos + 1, moRelaxed, moRelaxed):
        val = move(cell.data)
        cell.sequence.store(pos + uint64(Cap), moRelease)
        return true
    elif dif < 0:
      return false # Queue is empty
    else:
      pos = q.dequeuePos.load(moRelaxed)

proc pop*[T; Cap: static int](q: ptr MpmcQueue[T, Cap], val: var T): bool {.inline.} =
  pop(q[], val)

proc pop*[T; Cap: static int](q: var MpmcQueue[T, Cap]): Option[T] =
  ## Ergonomic Option pop: Returns Some(item) or None.
  var val: T
  if q.pop(val):
    result = some(val)
  else:
    result = none(T)

proc pop*[T; Cap: static int](q: ptr MpmcQueue[T, Cap]): Option[T] {.inline.} =
  pop(q[])

proc len*[T; Cap: static int](q: var MpmcQueue[T, Cap]): int {.inline.} =
  ## Returns the approximate number of elements currently queued.
  let enq = q.enqueuePos.load(moAcquire)
  let deq = q.dequeuePos.load(moAcquire)
  if enq >= deq:
    result = min(int(enq - deq), Cap)
  else:
    result = 0

proc len*[T; Cap: static int](q: MpmcQueue[T, Cap]): int {.inline.} =
  let enq = q.enqueuePos.load(moAcquire)
  let deq = q.dequeuePos.load(moAcquire)
  if enq >= deq:
    result = min(int(enq - deq), Cap)
  else:
    result = 0

proc len*[T; Cap: static int](q: ptr MpmcQueue[T, Cap]): int {.inline.} =
  len(q[])

proc empty*[T; Cap: static int](q: var MpmcQueue[T, Cap]): bool {.inline.} =
  q.len == 0

proc empty*[T; Cap: static int](q: MpmcQueue[T, Cap]): bool {.inline.} =
  q.len == 0

proc empty*[T; Cap: static int](q: ptr MpmcQueue[T, Cap]): bool {.inline.} =
  q[].empty

proc full*[T; Cap: static int](q: var MpmcQueue[T, Cap]): bool {.inline.} =
  q.len >= Cap

proc full*[T; Cap: static int](q: MpmcQueue[T, Cap]): bool {.inline.} =
  q.len >= Cap

proc full*[T; Cap: static int](q: ptr MpmcQueue[T, Cap]): bool {.inline.} =
  q[].full

# =============================================================================
# Feature 34: `ThreadPool` & `parallelFor`
# =============================================================================

type
  Task* = proc() {.gcsafe.}

  JobProc = proc(arg: pointer) {.nimcall, gcsafe.}

  Job = object
    fn: JobProc
    arg: pointer
    cleanup: JobProc

  ThreadPool* = object
    ## Fixed worker thread pool with OS condition variable parking at 0% idle CPU.
    threads: seq[Thread[ptr ThreadPool]]
    queue: ptr UncheckedArray[Job]
    queueCap: int
    queueHead: int
    queueTail: int
    queueCount: int
    numWorkers: int
    lock: SysLock
    when defined(windows):
      condWork: WinCondVar
    elif defined(posix):
      condWork: PthreadCondRaw
    running: bool
    isShutDown: bool
    threadsStarted: Atomic[bool]

proc `=copy`*(dest: var ThreadPool, src: ThreadPool) {.
  error: "ThreadPool cannot be copied; pass by pointer or var reference".}

proc workerProc(pool: ptr ThreadPool) {.thread.} =
  while true:
    var job = Job(fn: nil, arg: nil, cleanup: nil)

    acquire(pool.lock)
    while pool.running and pool.queueCount == 0:
      when defined(windows):
        discard winSleepConditionVariableSRW(addr pool.condWork, addr pool.lock.raw, 0xFFFFFFFF'u32, 0'u32)
      elif defined(posix):
        discard pthread_cond_wait(addr pool.condWork, addr pool.lock.raw)

    if pool.queueCount > 0:
      job = pool.queue[pool.queueHead]
      pool.queue[pool.queueHead] = Job(fn: nil, arg: nil, cleanup: nil)
      pool.queueHead = (pool.queueHead + 1) mod pool.queueCap
      dec(pool.queueCount)

    let shouldExit = (not pool.running) and (pool.queueCount == 0) and (job.fn == nil)
    release(pool.lock)

    if job.fn != nil:
      try:
        job.fn(job.arg)
      except CatchableError, Defect:
        discard
      finally:
        if job.cleanup != nil:
          job.cleanup(job.arg)
    elif shouldExit:
      break

proc ensureWorkers(pool: var ThreadPool) =
  if not pool.threadsStarted.load(moAcquire):
    acquire(pool.lock)
    if not pool.threadsStarted.load(moRelaxed) and pool.running and not pool.isShutDown:
      let count = if pool.numWorkers > 0: pool.numWorkers else: max(1, countProcessors())
      pool.threads = newSeq[Thread[ptr ThreadPool]](count)
      for i in 0 ..< count:
        createThread(pool.threads[i], workerProc, addr pool)
      pool.threadsStarted.store(true, moRelease)
    release(pool.lock)

proc initThreadPool*(numThreads: int = 0): ThreadPool =
  ## Initializes a ThreadPool with the specified number of worker threads (default: CPU cores).
  let count = if numThreads > 0: numThreads else: max(1, countProcessors())
  const InitialCapacity = 2048
  result.queueCap = InitialCapacity
  result.queue = cast[ptr UncheckedArray[Job]](allocShared0(sizeof(Job) * InitialCapacity))
  result.queueHead = 0
  result.queueTail = 0
  result.queueCount = 0
  result.numWorkers = count
  result.lock = initSysLock()
  when defined(windows):
    winInitializeConditionVariable(addr result.condWork)
  elif defined(posix):
    discard pthread_cond_init(addr result.condWork, nil)
  result.running = true
  result.isShutDown = false
  result.threadsStarted.store(false, moRelaxed)

proc initThreadPool*(pool: var ThreadPool, numThreads: int = 0) =
  ## Initializes an existing ThreadPool in-place and starts worker threads immediately.
  let count = if numThreads > 0: numThreads else: max(1, countProcessors())
  const InitialCapacity = 2048
  pool.queueCap = InitialCapacity
  pool.queue = cast[ptr UncheckedArray[Job]](allocShared0(sizeof(Job) * InitialCapacity))
  pool.queueHead = 0
  pool.queueTail = 0
  pool.queueCount = 0
  pool.numWorkers = count
  pool.lock = initSysLock()
  when defined(windows):
    winInitializeConditionVariable(addr pool.condWork)
  elif defined(posix):
    discard pthread_cond_init(addr pool.condWork, nil)
  pool.running = true
  pool.isShutDown = false
  pool.threadsStarted.store(false, moRelaxed)
  pool.ensureWorkers()

proc newThreadPool*(numThreads: int = 0): ptr ThreadPool =
  ## Allocates and initializes a ThreadPool on the shared heap.
  result = cast[ptr ThreadPool](allocShared0(sizeof(ThreadPool)))
  initThreadPool(result[], numThreads)

proc pushJob(pool: var ThreadPool, job: Job) =
  acquire(pool.lock)
  if not pool.running:
    release(pool.lock)
    raise newException(ValueError, "Cannot submit job on stopped ThreadPool")

  # Dynamic expansion of queue buffer if full
  if pool.queueCount == pool.queueCap:
    let oldCap = pool.queueCap
    let newCap = oldCap * 2
    let newQueue = cast[ptr UncheckedArray[Job]](allocShared0(sizeof(Job) * newCap))
    for i in 0 ..< pool.queueCount:
      newQueue[i] = pool.queue[(pool.queueHead + i) mod oldCap]
    deallocShared(pool.queue)
    pool.queue = newQueue
    pool.queueCap = newCap
    pool.queueHead = 0
    pool.queueTail = pool.queueCount

  pool.queue[pool.queueTail] = job
  pool.queueTail = (pool.queueTail + 1) mod pool.queueCap
  inc(pool.queueCount)

  when defined(windows):
    winWakeConditionVariable(addr pool.condWork)
  elif defined(posix):
    discard pthread_cond_signal(addr pool.condWork)
  release(pool.lock)

type TaskEnv = object
  task: Task

proc runTaskEnv(p: pointer) {.nimcall, gcsafe.} =
  let env = cast[ptr TaskEnv](p)
  if env.task != nil:
    env.task()

proc freeTaskEnv(p: pointer) {.nimcall, gcsafe.} =
  let env = cast[ptr TaskEnv](p)
  if env != nil:
    reset(env.task)
    deallocShared(env)

proc spawn*(pool: var ThreadPool, task: proc() {.gcsafe.}) =
  ## Submits a task closure for asynchronous execution in the thread pool.
  pool.ensureWorkers()
  let env = cast[ptr TaskEnv](allocShared0(sizeof(TaskEnv)))
  env.task = task
  let job = Job(fn: runTaskEnv, arg: env, cleanup: freeTaskEnv)
  try:
    pool.pushJob(job)
  except CatchableError, Defect:
    freeTaskEnv(env)
    raise

proc spawn*(pool: ptr ThreadPool, task: proc() {.gcsafe.}) {.inline.} =
  spawn(pool[], task)

proc shutdown*(pool: var ThreadPool) =
  ## Gracefully terminates the thread pool, draining queued tasks and joining all worker threads.
  acquire(pool.lock)
  if pool.isShutDown:
    release(pool.lock)
    return
  pool.isShutDown = true
  pool.running = false
  when defined(windows):
    winWakeAllConditionVariable(addr pool.condWork)
  elif defined(posix):
    discard pthread_cond_broadcast(addr pool.condWork)
  release(pool.lock)

  if pool.threadsStarted.load(moAcquire) and pool.threads.len > 0:
    for i in 0 ..< pool.threads.len:
      joinThread(pool.threads[i])
    pool.threads.setLen(0)

  acquire(pool.lock)
  if pool.queue != nil:
    while pool.queueCount > 0:
      var job = pool.queue[pool.queueHead]
      pool.queueHead = (pool.queueHead + 1) mod pool.queueCap
      dec(pool.queueCount)
      if job.cleanup != nil and job.arg != nil:
        try:
          job.cleanup(job.arg)
        except CatchableError, Defect:
          discard
    deallocShared(pool.queue)
    pool.queue = nil
  release(pool.lock)

proc shutdown*(pool: ptr ThreadPool) {.inline.} =
  shutdown(pool[])

proc `=destroy`*(pool: var ThreadPool) =
  if pool.running and not pool.isShutDown:
    try:
      pool.shutdown()
    except:
      discard
  elif pool.queue != nil:
    acquire(pool.lock)
    if pool.queue != nil:
      deallocShared(pool.queue)
      pool.queue = nil
    release(pool.lock)

type ChunkJob = object
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

proc parallelFor*(pool: var ThreadPool, start, `end`: int, fn: proc(s, e: int) {.gcsafe.}) =
  ## Partitions the half-open range [start, end) into balanced chunks across worker threads.
  ## Blocks until all chunks complete.
  if start >= `end`:
    return

  pool.ensureWorkers()
  let totalItems = `end` - start
  let numWorkers = if pool.threadsStarted.load(moAcquire) and pool.threads.len > 0:
                     pool.threads.len
                   elif pool.numWorkers > 0:
                     pool.numWorkers
                   else:
                     max(1, countProcessors())
  let numChunks = min(totalItems, numWorkers * 2)
  let chunkSize = (totalItems + numChunks - 1) div numChunks

  var wg = initWaitGroup()
  let wgPtr = addr wg
  let fnPtr = unsafeAddr fn

  var jobs = newSeq[ChunkJob](numChunks)
  var cur = start
  var idx = 0
  var pushedChunks = 0
  try:
    while cur < `end`:
      let chunkEnd = min(cur + chunkSize, `end`)
      jobs[idx].s = cur
      jobs[idx].e = chunkEnd
      jobs[idx].wg = wgPtr
      jobs[idx].fn = fnPtr

      wgPtr.add(1)
      let job = Job(fn: runChunkJob, arg: addr jobs[idx], cleanup: nil)
      pool.pushJob(job)
      inc(pushedChunks)
      cur = chunkEnd
      inc(idx)

    wgPtr.wait()
  except CatchableError, Defect:
    if pushedChunks > 0:
      wgPtr.wait()
    raise

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

# =============================================================================
# Global Default ThreadPool Facade
# =============================================================================

var gDefaultPool: ptr ThreadPool
var gDefaultPoolLock: SysLock

proc getDefaultPool*(): ptr ThreadPool =
  ## Returns the process-wide shared default ThreadPool instance, initializing it lazily.
  if gDefaultPool == nil:
    withLock(gDefaultPoolLock):
      if gDefaultPool == nil:
        gDefaultPool = newThreadPool()
  return gDefaultPool

proc spawn*(task: proc() {.gcsafe.}) {.inline.} =
  ## Spawns a task on the global default ThreadPool.
  getDefaultPool().spawn(task)

proc parallelFor*(start, `end`: int, fn: proc(s, e: int) {.gcsafe.}) {.inline.} =
  ## Runs parallelFor on the global default ThreadPool.
  getDefaultPool().parallelFor(start, `end`, fn)

proc parallelFor*(start, `end`: int, fn: proc(i: int) {.gcsafe.}) {.inline.} =
  ## Runs single-item parallelFor on the global default ThreadPool.
  getDefaultPool().parallelFor(start, `end`, fn)

proc shutdownThreadPool*() =
  ## Shuts down the global default ThreadPool and frees its resources.
  if gDefaultPool != nil:
    withLock(gDefaultPoolLock):
      if gDefaultPool != nil:
        gDefaultPool.shutdown()
        deallocShared(gDefaultPool)
        gDefaultPool = nil
