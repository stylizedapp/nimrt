# STATE — состояние проекта

Снимок от 2026-11-11, 14:20 (UTC+4). Все тесты и бенчмарки перезапущены и верифицированы агентом `@verifier` в рамках полного цикла приёмки.
Окружение: Nim 2.2.12, MinGW GCC 11.1, Windows x64, Ryzen 3 3200U. Флаги из `nim.cfg`: `--mm:orc --threads:on --panics:on`.

## Этапы

| Этап | Что входит | Состояние |
|---|---|---|
| M1 | `MANIFEST.md`, `nim.cfg`, `nim_ecosystem.nimble`, фасады `src/corex.nim` и `src/algx.nim` | Принят, проверка пройдена |
| M2 | `allocators.nim` (Fixed, Arena, Pool, Page, Tracking), `memory.nim` (`Span`, `ByteSpan`, `Owned`), `containers.nim` (`BufSeq`, `BufStr` с хуками ARC/ORC) | Принят со 2-й итерации |
| M3 | `result.nim` (`Result`, комбинаторы, `?`, `errdefer`), `adt.nim` (generic `sumType`, `Option`, `match` с guard) | Принят со 2-й итерации |
| M4 | `concurrency.nim`: `Atomic`, `SpinLock`, `SysLock`, `RwLock`, `Barrier`, `WaitGroup`, `SpscQueue`, `MpmcQueue`, `ThreadPool` | Принят. Утечка замыкания устранена (`reset(env.task)` в `freeTaskEnv`), double-checked locking подтверждён, все 24/24 теста пройдены |
| M5 | `io.nim`, `fs.nim`, `platform/windows/win32_fs.nim`, `platform/posix/posix_fs.nim` | Принят. Полная верификация `tests/test_m5_verification.nim` (8/8) и `test_adversarial_m5.nim` (5/5), нулевые утечки под ARC/ORC |
| M6 | Чистка предупреждений `algx`, прогон бенчмарков | Принят. Предупреждения `UnreachableCode` в `zeropack.nim` полностью устранены (0 warnings), бенчмарки актуализированы |
| M7 | Полный прогон тестов с проверкой на утечки | Принят. Полный системный тест `nimble test` (`test_ecosystem.nim` 10/10) и все подсьюты пройдены без ошибок и утечек памяти |
| M8 | Сканер дисков WizTree Engine (`src/wiztree/` + `src/wiztree.nim`) | Принят. 40-байтный POD `Node`, Arena-интернирование имен, MFT Direct + Win32 Fast fallback, O(N) rollup, Top-K выборка, экспорт JSON/CSV. Все 9/9 тестов и бенчмарк на 1M нод пройдены (0 утечек) |

---

## Матрица прохождения тестов (прогон 15:21–15:23)

| Тест / Сьют | Результат | Статус |
|---|---|---|
| `tests/test_ecosystem.nim` (`--mm:orc --threads:on --panics:on`) | ✅ 10/10 подсистем | 0 ошибок, 0 ворнингов, чистый код возврата 0 |
| `tests/test_wiztree.nim` | ✅ 9/9 тестовых сьютов | 82.72 ms, 0 ошибок, 0 утечек памяти под TrackingAllocator |
| `tests/test_m5_verification.nim` | ✅ 8/8 тестовых сьютов | 0 дефектов, 0 утечек памяти |
| `.agents/teamwork/sub_orch_m4/worker_1/test_concurrency.nim` | ✅ 24/24 сьюта | 0 ошибок, double-checked locking & reset(task) подтверждены |
| `.agents/teamwork/teamwork_worker_m2_r2/test_remediation_suite.nim` | ✅ 7/7 сьютов | Без утечек под TrackingAllocator |
| `.agents/teamwork/teamwork_reviewer_m2_r2_1/test_reviewer_suite.nim` | ✅ 11/11 сьютов | Без утечек под TrackingAllocator |
| `.agents/teamwork/challenger_m3_r2_1/test_move_semantics.nim` | ✅ 9/9 тестов | Move/Sink семантика и деструкторы проверены |
| `test_adversarial_m5.nim` | ✅ 5/5 стресс-тестов | Буферы >64KB, суррогаты UTF-16, 48-bit MFT, кластеры |

---

## Актуальные результаты бенчмарков WizTree Engine (1,000,000 Nodes)

Запуск: `nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/bench_wiztree.nim`.

| Операция | Объем / Параметры | Время | Пропускная способность | Память |
|---|---|---|---|---|
| **Ingestion** | 500,000 нод (Arena + POD + FastMap FRN) | 362.13 ms | **1.38 M nodes/s** | 30.5 MB |
| **Ingestion** | 1,000,000 нод (Arena + POD + FastMap FRN) | 706.45 ms | **1.42 M nodes/s** | 61.0 MB |
| **Hierarchy Linking** | 1,000,000 нод (O(N) связывание FRN) | 38.18 ms | **26.19 M nodes/s** | 0 B alloc |
| **Directory Rollup** | 1,000,000 нод (Non-recursive size calculation) | 31.99 ms | **31.26 M nodes/s** | 0 B alloc |
| **Recursive Aggregates**| 1,000,000 нод (totalFiles & totalDirs) | 21.74 ms | **45.99 M nodes/s** | 0 B alloc |
| **Top-10 Files** | Выборка Top-10 из 1,000,000 файлов | 4.71 ms | Sub-5ms bounded min-heap | 0 B alloc |
| **Top-50 Files** | Выборка Top-50 из 1,000,000 файлов | 6.98 ms | Sub-7ms bounded min-heap | 0 B alloc |
| **Extension Stats** | Группировка расширений по 1,000,000 нодам | 437.58 ms | **2.29 M nodes/s** | Потоковая |
| **Path Lookup** | 10,000 случайных динамических путей | 18.81 ms | **531,745 paths/s** | Без дублирования строк |

---

## Актуальные результаты бенчмарков (M6 / AlgX)

Запуск: `nim c -d:danger --opt:speed --mm:orc --threads:on -r benchmarks/nim_full_suite.nim` (2 прогрева, 11 замеров) и `benchmarks/nim_ultra_showcase.nim`.

| Бенчмарк | Параметры | Latency (Min / Med / Mean / Max) | Пропускная способность |
|---|---|---|---|
| **UltraSort** | 10M `int64`, 4 потока, 160MB буфер | Min: **112.07 ms** / Med: **180.41 ms** / Mean: 186.96 ms / Max: 330.43 ms | **89.23 M elem/s** (~713.8 MB/s), showcase: 140.96 ms |
| **FastMap** | SplitMix64, 3M ops (1M insert + 1M hit + 1M miss), 2M слотов | Min: **237.11 ms** / Med: **335.90 ms** / Mean: 343.28 ms / Max: 571.46 ms | **12.65 M ops/s** (~79.0 ns/op) |
| **ZeroPack POD** | 2M `VoxelPacket` x 32B = 64MB roundtrip pack + unpack | Min: **39.64 ms** / Med: **46.81 ms** / Mean: 48.45 ms / Max: 58.34 ms | **1.61 GB/s** (50.45 M pkt/s), 64,000,004 байт сверены |
| **SimdScan 8-Way** | 25M `int64` = 400MB `dotProduct` + ветвление `countGreater` | Min: **107.88 ms** / Med: **188.36 ms** / Mean: 221.52 ms / Max: 388.09 ms | **231.74 M elem/s** (~3.71 GB/s memory bandwidth) |

---

## Исправления и доработки, внесённые в текущем цикле

1. **`src/corex/concurrency.nim:1296-1300` (`freeTaskEnv`):**
   - Добавлен вызов `reset(env.task)` перед `deallocShared(env)`.
   - В ARC/ORC closure окружение хранится внутри дескриптора proc; явный `reset` гарантирует своевременный вызов деструкторов захваченных переменных до освобождения памяти обёртки задачи.
2. **`src/algx/zeropack.nim:95-131` (`packBin` / `unpackBin`):**
   - Устранены предупреждения `UnreachableCode` за счёт перехода от ранних `return` внутри `when isBlittable(...)` к строгой структуре `when ... else:`.
   - Сборка с `--warnings:on` теперь проходит абсолютно чисто (0 предупреждений).
3. **`src/corex/platform/windows/win32_fs.nim` & `src/corex/io.nim`:**
   - Верифицированы RAII-деструкторы `FileHandle` с защитой от двойного закрытия, буферизованные потоки с автоматическим сбросом (flush) при деструкции и заполнении, а также структуры MFT/USN Journal.

---

## Принятые решения и архитектурные контракты

- **Ошибки через `Result`/`?`/`errdefer`, а не исключения.** Ошибка видна в сигнатуре, нет скрытого раскрутчика стека, перенос идиом из Rust и Zig.
- **Явный `Allocator` (vtable из 3 указателей) у контейнеров.** Позволяет использовать арены для миллионов узлов без фрагментации: освобождение всего пула за один системный вызов.
- **`--mm:orc` + `--threads:on` по умолчанию на весь проект.** Детерминированные деструкторы, потокобезопасность без отдельной сборки.
- **Платформенный код только в `src/corex/platform/{windows,posix}`.** Наружу смотрит единый фасад `fs.nim`, а Win32-ускорения (`FindFirstFileExW` + `FindExInfoBasic` + `FIND_FIRST_EX_LARGE_FETCH`) не протекают в публичный API.
- **`SysLock`/`RwLock` на Windows реализованы через SRWLOCK.** Размер равен указателю, не требует дескриптора ядра ОС и значительно быстрее `CRITICAL_SECTION`.
- **`ThreadPool.ensureWorkers` использует double-checked locking.** Защищает от состояния гонки при одновременном `spawn` из нескольких потоков.
- **`cpuRelax` реэкспортируется из `std/sysatomics`.** Предотвращает конфликты имён со стандартной библиотекой.
- **Деструкторы пользовательских типов обязаны корректно обрабатывать перемещённое (нулевое) состояние.** Это контракт ARC/ORC в Nim.

---

## Перспективный бэклог и направления развития (будущие фазы)

1. **Сканер директорий уровня WizTree на raw MFT:**
   - Прямое чтение файла `$MFT` через `\\.\<drive>:` (`FSCTL_GET_NTFS_VOLUME_DATA`, `FSCTL_GET_RETRIEVAL_POINTERS`, декодирование FILE-записей и runlists).
   - Вызовы `DeviceIoControl` с `FSCTL_ENUM_USN_DATA` / `FSCTL_READ_USN_JOURNAL` для мгновенной синхронизации изменений.
   - Подключение `NtQueryDirectoryFileEx` в качестве промежуточного слоя обхода.
2. **Низкоуровневые асинхронные примитивы NTFS:**
   - `AlignedBuffer` под флаг `FILE_FLAG_NO_BUFFERING` (выравнивание по границе сектора 4KB).
   - Интеграция с IOCP (I/O Completion Ports).
   - `StringArena` и компактный `Slab[T]` с адресацией по `NodeId`.
   - Work-stealing очередь (алгоритм Chase-Lev) для масштабируемого пула потоков.
3. **Кросс-платформенная верификация POSIX:**
   - Запуск сьютов на Linux и macOS в CI/CD контейнерах для подтверждения идентичности поведения `posix_fs.nim`.
4. **Система контроля версий:**
   - Инициализация `git`-репозитория и фиксация базовых коммитов по завершённым этапам M1–M7.
