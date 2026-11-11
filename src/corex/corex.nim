## corex — Единый фундамент новой экосистемы Nim
##
## Объединяет лучшие возможности Rust, Zig и Python:
## - `result`: `Result[T, E]`, оператор `?`, `errdefer`
## - `adt`: Алгебраические типы (`sumType`) и `match` с деструктуризацией
## - `allocators`: Явные аллокаторы (`ArenaAllocator`, `FixedBufferAllocator`, `TrackingAllocator`, `PoolAllocator`, `PageAllocator`)
## - `memory`: Безопасные срезы (`Span[T]`, `ByteSpan`), парсинг (`ByteReader`) и умные указатели (`Owned[T]`)
## - `containers`: Аллокаторно-зависимые `BufSeq[T]` и `BufStr` с ARC/ORC хуками
## - `concurrency`: Блокировки и lock-free примитивы (`Atomic[T]`, `SpinLock`, `SysLock`, `RwLock`, `Barrier`, `WaitGroup`, `SpscQueue`, `MpmcQueue`, `ThreadPool`)
## - `traits`: Полиморфизм через fat-pointer (`defTrait` / `DynTrait`) без аллокаций в куче
## - `testing`: Автопроверка утечек памяти (`testWithLeakCheck`), фаззинг (`quickCheck`) и `bench`
## - `io`: Move-only RAII `FileHandle`, 64KB `BufferedReader` и `BufferedWriter` с auto-flush
## - `fs`: Кросс-платформенная файловая система (`FileStat`, `DirEntry`, `VolumeInfo`, `walkDirFast`, `getVolumeInfo`)

import ./result
import ./adt
import ./allocators
import ./memory
import ./containers
import ./concurrency
import ./traits
import ./testing
import ./io
import ./fs

export result, adt, allocators, memory, containers, concurrency, traits, testing, io, fs
