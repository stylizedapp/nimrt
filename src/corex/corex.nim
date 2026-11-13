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

## - `bufmap`: Аллокаторно-зависимая SwissTable хэш-таблица `BufMap[K, V]`
## - `slab`: Пул объектов `Slab[T]` с O(1) alloc/free и стабильными `SlabId`
## - `stringarena`: Временная арена строк `StringArena` с O(1) reset
## - `arc`: Потокобезопасный smart-pointer `Arc[T]` с контролем аллокатора
## - `diagnostic`: Диагностический рендерер компиляторного уровня `Diagnostic`
## - `smallvec`: Стековый вектор `SmallVec[T, N]` с переполнением в аллокатор
## - `interner`: Строковый дедупликатор `StringInterner` с `InternedStr`
## - `bitops`: Быстрые битовые интринсики, стековый `BitSet[N]` и SWAR примитивы
## - `unicode`: RFC 3629 валидация, декодирование рун, UAX #29 графемы и displayWidth
## - `async`: Асинхронный I/O реактор на базе Windows IOCP и интеграция с Work-Stealing пулом потоков
## - `mft`: Парсер Master File Table (MFT) NTFS, многосекторные FIXUP массивы и прямой стриминг томов
## - `signals`: Высокопроизводительный Data-Oriented реактивный движок (SolidJS/Slint-style)

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
import ./bufmap
import ./slab
import ./stringarena
import ./arc
import ./diagnostic
import ./smallvec
import ./interner
import ./bitops
import ./unicode
import ./async
import ./mft
import ./signals

export result, adt, allocators, memory, containers, concurrency, traits, testing, io, fs, bufmap, slab, stringarena, arc, diagnostic, smallvec, interner, bitops, unicode, async, mft, signals
