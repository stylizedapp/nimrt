## corex/concurrency — High-Performance Concurrency & Thread Synchronization Facade
##
## Re-exports cohesive submodules:
## - `concurrency/primitives`: `Atomic[T]`, `MemoryOrder`, `SpinLock`, `SysLock`, `RwLock`,
##   `CondVar`, RAII guards (`withLock`, `withReadLock`, `withWriteLock`), `Barrier`,
##   `WaitGroup`, `SpscQueue`, `MpmcQueue`
## - `concurrency/pool`: `ThreadPool`, work-stealing scheduler, and explicit default pool singleton
## - `concurrency/parallel`: Cooperative `parallelFor` & `tryParallelFor`

import ./concurrency/[primitives, pool, parallel]
export primitives, pool, parallel
