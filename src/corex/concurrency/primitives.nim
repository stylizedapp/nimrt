## corex/concurrency/primitives — OS & Lock-Free Synchronization Primitives
##
## Provides zero-overhead, cross-platform synchronization primitives:
## - `Atomic[T]` and `MemoryOrder`
## - `SpinLock` (TTAS with exponential backoff and hardware `cpuRelax`)
## - `SysLock` (Windows SRWLOCK exclusive, POSIX pthread_mutex_t)
## - `RwLock` (Reader-writer lock: Windows SRWLOCK, POSIX pthread_rwlock_t)
## - `CondVar` (Cross-platform condition variable for `SysLock`)
## - RAII Lock Guards (`withLock`, `withReadLock`, `withWriteLock`)
## - `Barrier` (Cyclic rendezvous barrier with generation counter)
## - `WaitGroup` (Atomic counter coordination primitive with Defect guard)
## - `SpscQueue[T, Cap]` (Lock-free SPSC circular queue with 64-byte cache alignment)
## - `MpmcQueue[T, Cap]` (Dmitry Vyukov bounded MPMC queue with atomic sequence turns)

import std/atomics
import std/sysatomics
import ../adt

export atomics.Atomic, atomics.AtomicFlag, atomics.atomicInc, atomics.atomicDec
export sysatomics.cpuRelax, sysatomics.fence
export adt.Option, adt.Some, adt.None, adt.some, adt.none, adt.isSome, adt.isNone, adt.get, adt.getOr

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

proc initAtomic*[T](val: T): Atomic[T] {.inline.} =
  result.store(val, moRelaxed)

proc init*[T](location: var Atomic[T], val: T) {.inline.} =
  location.store(val, moRelaxed)

proc load*[T](location: var Atomic[T], order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.load(location, toStd(order))

proc load*[T](location: ptr Atomic[T], order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.load(location[], toStd(order))

proc store*[T](location: var Atomic[T], desired: T, order: MemoryOrder = SeqCst) {.inline.} =
  atomics.store(location, desired, toStd(order))

proc store*[T](location: ptr Atomic[T], desired: T, order: MemoryOrder = SeqCst) {.inline.} =
  atomics.store(location[], desired, toStd(order))

proc exchange*[T](location: var Atomic[T], desired: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.exchange(location, desired, toStd(order))

proc exchange*[T](location: ptr Atomic[T], desired: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.exchange(location[], desired, toStd(order))

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

proc fetchAdd*[T: SomeInteger](location: var Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.fetchAdd(location, value, toStd(order))

proc fetchAdd*[T: SomeInteger](location: ptr Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  fetchAdd(location[], value, order)

proc fetchSub*[T: SomeInteger](location: var Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  atomics.fetchSub(location, value, toStd(order))

proc fetchSub*[T: SomeInteger](location: ptr Atomic[T], value: T, order: MemoryOrder = SeqCst): T {.inline.} =
  fetchSub(location[], value, order)

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
  atomics.fence(toStd(order))

proc signalFence*(order: MemoryOrder = SeqCst) {.inline.} =
  atomics.signalFence(toStd(order))

# =============================================================================
# Feature 26: `SpinLock` (TTAS with Exponential Backoff)
# =============================================================================

type
  SpinLock* = object
    ## User-space spinlock utilizing Test-and-Test-and-Set (TTAS) and hardware cpuRelax.
    ## Footprint: 1 byte, pure value object, zero heap allocations, safe when zero-initialized.
    state: Atomic[bool]

proc initSpinLock*(): SpinLock {.inline.} =
  result.state.store(false, moRelaxed)

proc initSpinLock*(lock: var SpinLock) {.inline.} =
  lock.state.store(false, moRelaxed)

proc tryAcquire*(lock: var SpinLock): bool {.inline.} =
  not lock.state.load(moRelaxed) and not lock.state.exchange(true, moAcquire)

proc tryAcquire*(lock: ptr SpinLock): bool {.inline.} =
  tryAcquire(lock[])

proc acquire*(lock: var SpinLock) {.inline.} =
  var backoff = 1
  const maxBackoff = 64
  while true:
    if not lock.state.exchange(true, moAcquire):
      return
    while lock.state.load(moRelaxed):
      for _ in 0 ..< backoff:
        cpuRelax()
      if backoff < maxBackoff:
        backoff = backoff shl 1

proc acquire*(lock: ptr SpinLock) {.inline.} =
  acquire(lock[])

proc release*(lock: var SpinLock) {.inline.} =
  lock.state.store(false, moRelease)

proc release*(lock: ptr SpinLock) {.inline.} =
  release(lock[])

# =============================================================================
# Feature 27: `SysLock` (OS Mutex) & `CondVar`
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

  CondVar* = object
    ## Cross-platform condition variable paired with `SysLock`.
    when defined(windows):
      raw: WinCondVar
    elif defined(posix):
      raw: PthreadCondRaw
    else:
      raw: pointer

proc `=copy`*(dest: var SysLock, src: SysLock) {.
  error: "SysLock is an OS synchronization primitive and cannot be copied; pass by pointer or var reference".}

proc `=copy`*(dest: var CondVar, src: CondVar) {.
  error: "CondVar is an OS synchronization primitive and cannot be copied; pass by pointer or var reference".}

proc initSysLock*(): SysLock {.inline.} =
  when defined(windows):
    winInitializeSRWLock(addr result.raw)
  elif defined(posix):
    discard pthread_mutex_init(addr result.raw, nil)

proc initSysLock*(lock: var SysLock) {.inline.} =
  when defined(windows):
    winInitializeSRWLock(addr lock.raw)
  elif defined(posix):
    discard pthread_mutex_init(addr lock.raw, nil)

proc acquire*(lock: var SysLock) {.inline.} =
  when defined(windows):
    winAcquireSRWLockExclusive(addr lock.raw)
  elif defined(posix):
    discard pthread_mutex_lock(addr lock.raw)

proc acquire*(lock: ptr SysLock) {.inline.} =
  acquire(lock[])

proc tryAcquire*(lock: var SysLock): bool {.inline.} =
  when defined(windows):
    result = winTryAcquireSRWLockExclusive(addr lock.raw) != 0'u8
  elif defined(posix):
    result = pthread_mutex_trylock(addr lock.raw) == 0

proc tryAcquire*(lock: ptr SysLock): bool {.inline.} =
  tryAcquire(lock[])

proc release*(lock: var SysLock) {.inline.} =
  when defined(windows):
    winReleaseSRWLockExclusive(addr lock.raw)
  elif defined(posix):
    discard pthread_mutex_unlock(addr lock.raw)

proc release*(lock: ptr SysLock) {.inline.} =
  release(lock[])

proc deinitSysLock*(lock: var SysLock) {.inline.} =
  when defined(posix):
    discard pthread_mutex_destroy(addr lock.raw)

proc deinitSysLock*(lock: ptr SysLock) {.inline.} =
  deinitSysLock(lock[])

proc initCondVar*(): CondVar {.inline.} =
  when defined(windows):
    winInitializeConditionVariable(addr result.raw)
  elif defined(posix):
    discard pthread_cond_init(addr result.raw, nil)

proc initCondVar*(cv: var CondVar) {.inline.} =
  when defined(windows):
    winInitializeConditionVariable(addr cv.raw)
  elif defined(posix):
    discard pthread_cond_init(addr cv.raw, nil)

proc wakeOne*(cv: var CondVar) {.inline.} =
  when defined(windows):
    winWakeConditionVariable(addr cv.raw)
  elif defined(posix):
    discard pthread_cond_signal(addr cv.raw)

proc wakeAll*(cv: var CondVar) {.inline.} =
  when defined(windows):
    winWakeAllConditionVariable(addr cv.raw)
  elif defined(posix):
    discard pthread_cond_broadcast(addr cv.raw)

proc waitCondVar*(cv: var CondVar, lock: var SysLock) {.inline.} =
  when defined(windows):
    discard winSleepConditionVariableSRW(addr cv.raw, addr lock.raw, 0xFFFFFFFF'u32, 0'u32)
  elif defined(posix):
    discard pthread_cond_wait(addr cv.raw, addr lock.raw)

proc deinitCondVar*(cv: var CondVar) {.inline.} =
  when defined(posix):
    discard pthread_cond_destroy(addr cv.raw)

# =============================================================================
# Feature 28: `RwLock` (Reader-Writer Lock)
# =============================================================================

type
  RwLock* = object
    when defined(windows):
      raw: SRWLockRaw
    elif defined(posix):
      raw: PthreadRwlockRaw
    else:
      raw: pointer

proc `=copy`*(dest: var RwLock, src: RwLock) {.
  error: "RwLock is an OS synchronization primitive and cannot be copied; pass by pointer or var reference".}

proc initRwLock*(): RwLock {.inline.} =
  when defined(windows):
    winInitializeSRWLock(addr result.raw)
  elif defined(posix):
    discard pthread_rwlock_init(addr result.raw, nil)

proc initRwLock*(lock: var RwLock) {.inline.} =
  when defined(windows):
    winInitializeSRWLock(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_init(addr lock.raw, nil)

proc acquireRead*(lock: var RwLock) {.inline.} =
  when defined(windows):
    winAcquireSRWLockShared(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_rdlock(addr lock.raw)

proc acquireRead*(lock: ptr RwLock) {.inline.} =
  acquireRead(lock[])

proc tryAcquireRead*(lock: var RwLock): bool {.inline.} =
  when defined(windows):
    result = winTryAcquireSRWLockShared(addr lock.raw) != 0'u8
  elif defined(posix):
    result = pthread_rwlock_tryrdlock(addr lock.raw) == 0

proc tryAcquireRead*(lock: ptr RwLock): bool {.inline.} =
  tryAcquireRead(lock[])

proc releaseRead*(lock: var RwLock) {.inline.} =
  when defined(windows):
    winReleaseSRWLockShared(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_unlock(addr lock.raw)

proc releaseRead*(lock: ptr RwLock) {.inline.} =
  releaseRead(lock[])

proc acquireWrite*(lock: var RwLock) {.inline.} =
  when defined(windows):
    winAcquireSRWLockExclusive(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_wrlock(addr lock.raw)

proc acquireWrite*(lock: ptr RwLock) {.inline.} =
  acquireWrite(lock[])

proc tryAcquireWrite*(lock: var RwLock): bool {.inline.} =
  when defined(windows):
    result = winTryAcquireSRWLockExclusive(addr lock.raw) != 0'u8
  elif defined(posix):
    result = pthread_rwlock_trywrlock(addr lock.raw) == 0

proc tryAcquireWrite*(lock: ptr RwLock): bool {.inline.} =
  tryAcquireWrite(lock[])

proc releaseWrite*(lock: var RwLock) {.inline.} =
  when defined(windows):
    winReleaseSRWLockExclusive(addr lock.raw)
  elif defined(posix):
    discard pthread_rwlock_unlock(addr lock.raw)

proc releaseWrite*(lock: ptr RwLock) {.inline.} =
  releaseWrite(lock[])

proc acquire*(lock: var RwLock) {.inline.} = acquireWrite(lock)
proc acquire*(lock: ptr RwLock) {.inline.} = acquireWrite(lock[])
proc tryAcquire*(lock: var RwLock): bool {.inline.} = tryAcquireWrite(lock)
proc tryAcquire*(lock: ptr RwLock): bool {.inline.} = tryAcquireWrite(lock[])
proc release*(lock: var RwLock) {.inline.} = releaseWrite(lock)
proc release*(lock: ptr RwLock) {.inline.} = releaseWrite(lock[])

proc deinitRwLock*(lock: var RwLock) {.inline.} =
  when defined(posix):
    discard pthread_rwlock_destroy(addr lock.raw)

proc deinitRwLock*(lock: ptr RwLock) {.inline.} =
  deinitRwLock(lock[])

# =============================================================================
# Feature 29: RAII Lock Guards
# =============================================================================

template withLock*(lock: untyped, body: untyped): untyped =
  acquire(lock)
  try:
    body
  finally:
    release(lock)

template withReadLock*(lock: untyped, body: untyped): untyped =
  acquireRead(lock)
  try:
    body
  finally:
    releaseRead(lock)

template withWriteLock*(lock: untyped, body: untyped): untyped =
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
    partiesNum: int
    countNum: int
    generation: int
    lock: SysLock
    cond: CondVar

proc `=copy`*(dest: var Barrier, src: Barrier) {.
  error: "Barrier is a thread coordination primitive and cannot be copied; pass by pointer or var reference".}

proc initBarrier*(parties: int): Barrier =
  if parties <= 0:
    raiseAssert("Barrier parties must be positive")
  result.partiesNum = parties
  result.countNum = parties
  result.generation = 0
  initSysLock(result.lock)
  initCondVar(result.cond)

proc initBarrier*(b: var Barrier, parties: int) =
  if parties <= 0:
    raiseAssert("Barrier parties must be positive")
  b.partiesNum = parties
  b.countNum = parties
  b.generation = 0
  initSysLock(b.lock)
  initCondVar(b.cond)

proc wait*(b: var Barrier): bool {.discardable.} =
  acquire(b.lock)
  let gen = b.generation
  dec(b.countNum)
  if b.countNum == 0:
    inc(b.generation)
    b.countNum = b.partiesNum
    wakeAll(b.cond)
    release(b.lock)
    return true
  else:
    while b.generation == gen:
      waitCondVar(b.cond, b.lock)
    release(b.lock)
    return false

proc wait*(b: ptr Barrier): bool {.discardable, inline.} =
  wait(b[])

proc parties*(b: Barrier): int {.inline.} =
  b.partiesNum

proc parties*(b: ptr Barrier): int {.inline.} =
  b[].partiesNum

proc count*(b: var Barrier): int =
  acquire(b.lock)
  result = b.countNum
  release(b.lock)

proc count*(b: ptr Barrier): int {.inline.} =
  count(b[])

proc reset*(b: var Barrier) =
  acquire(b.lock)
  b.countNum = b.partiesNum
  inc(b.generation)
  wakeAll(b.cond)
  release(b.lock)

proc reset*(b: ptr Barrier) {.inline.} =
  reset(b[])

# =============================================================================
# Feature 31: `WaitGroup` (Atomic Counter Coordination)
# =============================================================================

type
  WaitGroup* = object
    counter: int
    lock: SysLock
    cond: CondVar

proc `=copy`*(dest: var WaitGroup, src: WaitGroup) {.
  error: "WaitGroup is a thread coordination primitive and cannot be copied; pass by pointer or var reference".}

proc initWaitGroup*(): WaitGroup =
  result.counter = 0
  initSysLock(result.lock)
  initCondVar(result.cond)

proc initWaitGroup*(wg: var WaitGroup) =
  wg.counter = 0
  initSysLock(wg.lock)
  initCondVar(wg.cond)

proc add*(wg: var WaitGroup, delta: int = 1) =
  ## Increments or decrements the WaitGroup counter by delta.
  ## Raises Defect if the counter becomes negative.
  acquire(wg.lock)
  wg.counter += delta
  if wg.counter < 0:
    release(wg.lock)
    raise newException(Defect, "negative WaitGroup counter")
  if wg.counter == 0:
    wakeAll(wg.cond)
  release(wg.lock)

proc add*(wg: ptr WaitGroup, delta: int = 1) {.inline.} =
  add(wg[], delta)

proc done*(wg: var WaitGroup) {.inline.} =
  wg.add(-1)

proc done*(wg: ptr WaitGroup) {.inline.} =
  done(wg[])

proc wait*(wg: var WaitGroup) =
  acquire(wg.lock)
  while wg.counter > 0:
    waitCondVar(wg.cond, wg.lock)
  release(wg.lock)

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
  when (Cap and (Cap - 1)) != 0 or Cap < 2:
    {.error: "SpscQueue Cap must be a power of two and >= 2".}
  result.tail.store(0'u64, moRelaxed)
  result.head.store(0'u64, moRelaxed)
  result.cachedHead = 0
  result.cachedTail = 0

proc initSpscQueue*[T; Cap: static int](q: var SpscQueue[T, Cap]) =
  when (Cap and (Cap - 1)) != 0 or Cap < 2:
    {.error: "SpscQueue Cap must be a power of two and >= 2".}
  q.tail.store(0'u64, moRelaxed)
  q.head.store(0'u64, moRelaxed)
  q.cachedHead = 0
  q.cachedTail = 0

proc newSpscQueue*[T; Cap: static int](): ptr SpscQueue[T, Cap] =
  result = cast[ptr SpscQueue[T, Cap]](allocShared0(sizeof(SpscQueue[T, Cap])))
  initSpscQueue(result[])

proc push*[T; Cap: static int](q: var SpscQueue[T, Cap], val: sink T): bool =
  const Mask = uint64(Cap - 1)
  let currentTail = q.tail.load(moRelaxed)
  if currentTail - q.cachedHead >= uint64(Cap):
    q.cachedHead = q.head.load(moAcquire)
    if currentTail - q.cachedHead >= uint64(Cap):
      return false
  q.buffer[int(currentTail and Mask)] = val
  q.tail.store(currentTail + 1, moRelease)
  return true

proc push*[T; Cap: static int](q: ptr SpscQueue[T, Cap], val: sink T): bool {.inline.} =
  push(q[], val)

proc pop*[T; Cap: static int](q: var SpscQueue[T, Cap], val: var T): bool =
  const Mask = uint64(Cap - 1)
  let currentHead = q.head.load(moRelaxed)
  if currentHead == q.cachedTail:
    q.cachedTail = q.tail.load(moAcquire)
    if currentHead == q.cachedTail:
      return false
  val = move(q.buffer[int(currentHead and Mask)])
  q.head.store(currentHead + 1, moRelease)
  return true

proc pop*[T; Cap: static int](q: ptr SpscQueue[T, Cap], val: var T): bool {.inline.} =
  pop(q[], val)

proc pop*[T; Cap: static int](q: var SpscQueue[T, Cap]): Option[T] =
  var val: T
  if q.pop(val):
    result = some(val)
  else:
    result = none(T)

proc pop*[T; Cap: static int](q: ptr SpscQueue[T, Cap]): Option[T] {.inline.} =
  pop(q[])

proc len*[T; Cap: static int](q: var SpscQueue[T, Cap]): int {.inline.} =
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
    enqueuePos {.align: CacheLineSize.}: Atomic[uint64]
    pad1: array[CacheLineSize - sizeof(Atomic[uint64]), byte]

    dequeuePos {.align: CacheLineSize.}: Atomic[uint64]
    pad2: array[CacheLineSize - sizeof(Atomic[uint64]), byte]

    cells {.align: CacheLineSize.}: array[Cap, MpmcCell[T]]

proc `=copy`*[T; Cap: static int](dest: var MpmcQueue[T, Cap], src: MpmcQueue[T, Cap]) {.
  error: "MpmcQueue cannot be copied; pass by pointer or var reference".}

proc initMpmcQueue*[T; Cap: static int](): MpmcQueue[T, Cap] =
  when (Cap and (Cap - 1)) != 0 or Cap < 2:
    {.error: "MpmcQueue Cap must be a power of two and >= 2".}
  result.enqueuePos.store(0'u64, moRelaxed)
  result.dequeuePos.store(0'u64, moRelaxed)
  for i in 0 ..< Cap:
    result.cells[i].sequence.store(uint64(i), moRelaxed)

proc initMpmcQueue*[T; Cap: static int](q: var MpmcQueue[T, Cap]) =
  when (Cap and (Cap - 1)) != 0 or Cap < 2:
    {.error: "MpmcQueue Cap must be a power of two and >= 2".}
  q.enqueuePos.store(0'u64, moRelaxed)
  q.dequeuePos.store(0'u64, moRelaxed)
  for i in 0 ..< Cap:
    q.cells[i].sequence.store(uint64(i), moRelaxed)

proc newMpmcQueue*[T; Cap: static int](): ptr MpmcQueue[T, Cap] =
  result = cast[ptr MpmcQueue[T, Cap]](allocShared0(sizeof(MpmcQueue[T, Cap])))
  initMpmcQueue(result[])

proc push*[T; Cap: static int](q: var MpmcQueue[T, Cap], val: sink T): bool =
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
      return false
    else:
      pos = q.enqueuePos.load(moRelaxed)

proc push*[T; Cap: static int](q: ptr MpmcQueue[T, Cap], val: sink T): bool {.inline.} =
  push(q[], val)

proc pop*[T; Cap: static int](q: var MpmcQueue[T, Cap], val: var T): bool =
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
      return false
    else:
      pos = q.dequeuePos.load(moRelaxed)

proc pop*[T; Cap: static int](q: ptr MpmcQueue[T, Cap], val: var T): bool {.inline.} =
  pop(q[], val)

proc pop*[T; Cap: static int](q: var MpmcQueue[T, Cap]): Option[T] =
  var val: T
  if q.pop(val):
    result = some(val)
  else:
    result = none(T)

proc pop*[T; Cap: static int](q: ptr MpmcQueue[T, Cap]): Option[T] {.inline.} =
  pop(q[])

proc len*[T; Cap: static int](q: var MpmcQueue[T, Cap]): int {.inline.} =
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
