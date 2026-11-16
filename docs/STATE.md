# STATE — состояние проекта

Снимок от 2026-11-16 (UTC+4). Статус подготовки релиза **v0.1.0 (Windows-first)**: включает `corex`, `algx`, `nimui` (Vulkan 1.1+ SDF, практический subset HTML5/CSS3 + опциональный sandboxed QuickJS hybrid), экспериментальный компилятор `compiler/nim_safe` (`--mem-safe` / `--safe-mode` / `--check-safe-atf`) и приложения `apps/` (`wiztree`, `everything`, `html_desktop`, `html_css_studio`, `widget_gallery`, `nimui_demo`).
Окружение: Nim 2.2.12, MinGW GCC 11.1.0, Windows x64, AMD Ryzen 3 3200U. Флаги из `nim.cfg`: `--mm:orc --threads:on --panics:on`.

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
| M8 | Сканер дисков WizTree Engine (`apps/wiztree/`: `wiztree.nim`, `scanner.nim`, `tree.nim`, `types.nim`, `cli.nim`) | Принят. 40-байтный POD `Node`, Arena-интернирование имен, MFT Direct + Win32 Fast fallback, O(N) rollup, Top-K выборка, экспорт JSON/CSV. Тесты `tests/test_wiztree.nim` (9/9) и бенчмарк на 1M нод пройдены |
| M9 | Work-Stealing ThreadPool (`src/corex/workstealing.nim` + `src/corex/concurrency.nim`) | Принят. Chase-Lev lock-free deque на поток (LIFO push/pop, lock-free FIFO steal), батчевая инжекция (до 16 задач), cooperative `parallelFor`, устранение гонок цикла ORC, 0 утечек под ARC/ORC, до 10x ускорение под конкуренцией (935 M items/s на рекурсивном divide-and-conquer) |
| M10 | Расширение ядра (`bitops`, `unicode`), SWAR-ускорение (`swissmap`, `bufmap`, `heap`) и «железные» тесты | Принят. `BitSet[N]`, SWAR 8-byte matching, UAX #29 графемы (8.19M runes/s), UTF-8 (до 9.85 GB/s), $O(N)$ `heapify` (56.9M ops/s), 3.6x ускорение промахов в FastMap. 4/4 стресс-сьюта пройдены с 0 ошибок и 0 утечек |
| M11 | Zero-Exception Hardening & Безопасность ядра (`heap`, `swissmap`, `concurrency`, `win32_fs`) | Принят. Устранены `KeyError` и `ValueError` из горячих путей; `FastMap.get` и `BinaryHeap.tryPeek/tryPop` возвращают `Option[T]`; защита кучи в `-d:danger`; проверка Win32 API диска; удалены мусорные бинарники |
| M12 | Нативный IOCP Async рантайм & Парсер Raw MFT (`corex/async`, `corex/mft`, `win32_iocp`, `win32_mft`) | Принят. Батчевый IOCP (`GetQueuedCompletionStatusEx` до 64 пакетов), интеграция с Chase-Lev ThreadPool (0 утечек на 3072 асинхронных операциях); парсер 1024-байтных записей `$MFT` с валидацией FIXUP, декодером цепочек кластеров runlist для точного `fileSize` и `sizeOnDisk`, потоковым чтением томов `\\.\<drive>:`. Все тесты пройдены |
| M13 | Стабилизация ядра, Реактивный движок (`corex/signals`) и MFT+IOCP конвейер | Принят. Устранён dangling pointer в `OverlappedPool`, `gDefaultReactor`/`gDefaultPool` переведены на `Atomic[pointer]` с `moAcquire`/`moRelease`; zero-overhead реактивный граф `corex/signals` (Slab-backed узлы и рёбра, glitch-free diamond, динамическая отписка веток, батчинг, 10k циклов 0 утечек); парсинг `$ATTRIBUTE_LIST` (0x20) и дедупликация Hardlinks в MFT; Everything-Nim GUI интеграция `SearchIndex` и фикс утечек `AppState` через `=destroy(state[])` |
| M14 | Реактивный UI-фреймворк `nimui` + Vulkan 1.1+ бэкенд (`src/nimui/`, `src/nimui.nim`, `apps/nimui_demo/src/main.nim`) | Принят. Нулевые аллокации в Flexbox layout, атлас глифов (GDI coverage-битмапы, LRU), reverse Z-order hit-testing, O(1) VirtualList (1,000,000 элементов за 272 µs), Single-Draw-Call Vulkan 1.1+ инстансинг, реактивные сигналы `corex/signals`, `tests/test_nimui_layout.nim` (5/5 сьютов). Примечание: ранний Raycast Spotlight (`0.020 ms` CPU `buildDrawInstances`, `68 KB` trimmed headless RAM) позже заменён на **Singularity Lab** в `apps/nimui_demo` |
| M15 | QuickJS C Engine, `Allocator` Bridge & Философский валидатор (`src/nimui/js/`, `tools/build_quickjs.ps1`) | Принят. Собрана `libquickjs.a`, все аллокации QuickJS идут через `corex/allocators.Allocator` (0 утечек), добавлены проверки Rust (`var`, `==`/`!=`, `eval`/`Function`/`with`/`__proto__`, лимиты памяти/стека/шагов), Zig (`data-caps`), Python (`ui.*`/`Nim.*`) |
| M16 | Гибридный HTML5/CSS3 + Nim + QuickJS мост (`src/nimui/html_css.nim`, `src/nimui/js/html_js_bridge.nim`) | Принят. Сохранён строгий Zero-JS режим (`allowJs = false` по умолчанию) и добавлен гибридный режим с совместной работой `HtmlBindingRegistry` + `Signal[T]` + QuickJS DOM/стилей/событий/таймеров |
| M17 | Помодоро-таймер (1–3 сек) & `/browser` + Headless верификация (`apps/html_desktop/ui/pomodoro.html`, `tests/test_nimui_quickjs.nim`) | Принят. 4/4 сьюта QuickJS (включая 30-цикловый стресс с 0 утечек), headless PNG-скриншоты и интерактивная проверка в браузере (`/browser` `127.0.0.1:8765/pomodoro.html`) пройдены |
| M18 | Гибридный Memory-Safe компилятор (`compiler/nim_safe.nim`, `mem_safe_pass.nim`, `atf_c_checker.nim`, `bin/nim_safe.exe`) | Принят. Реализованы флаги `--mem-safe`, `--safe-mode`, `--check-safe-atf`, `--atf-report`, borrow checking (`varpartitions`), запрет сырых указателей/кастов/глобалов/исключений и пост-кодогенерационный анализ C-кода (ATF) до вызова GCC |
| M19 | Сьют верификации компилятора и документация (`tests/test_safe_compiler.nim`, `nim_ecosystem.nimble`) | Принят. Все 5 сьютов `test_safe_compiler.nim` и пост-кодогенерационная проверка `test_nimui_html_css.nim` (`[ATF-SAFE] 9 C modules, 27656 lines, 0 violations`) пройдены |

---

## Матрица прохождения тестов (прогон 15:21–15:23)

| Тест / Сьют | Результат | Статус |
|---|---|---|
| `tests/test_ecosystem.nim` (`--mm:orc --threads:on --panics:on`) | ✅ 10/10 подсистем | 0 ошибок, 0 ворнингов, чистый код возврата 0 |
| `tests/test_workstealing.nim` | ✅ 10/10 тестовых сьютов | 0 ошибок, проверено на 10 стресс-прогонах, 0 утечек |
| `tests/bench_workstealing.nim` | ✅ 4 бенчмарк-сценария | 935.89 M items/s (divide-and-conquer), 0 байт утечек под ORC |
| `tests/test_wiztree.nim` | ✅ 9/9 тестовых сьютов | 82.72 ms, 0 ошибок, 0 утечек памяти под TrackingAllocator |
| `tests/test_m5_verification.nim` | ✅ 8/8 тестовых сьютов | 0 дефектов, 0 утечек памяти |
| `tests/test_concurrency.nim` | ✅ 24/24 сьюта | Double-checked locking, WorkStealing, Atomics, WaitGroup |
| `tests/test_parallel_for_shutdown.nim` | ✅ 50 итераций | Watchdog проверка завершения без дедлоков |
| `tests/test_ironclad_signals.nim` | ✅ 5/5 тестов | 0 ошибок, glitch-free diamond, dynamic unsubscription, 10,000 циклов |
| `tests/test_ironclad_mft.nim` | ✅ 7/7 сьютов | 0 ошибок, `$ATTRIBUTE_LIST` 0x20 и Hardlink дедупликация |
| `tests/test_ironclad_async_iocp.nim` | ✅ 4/4 сьюта | 0 ошибок, 1024 concurrent read/write (`TrackingAllocator`) |
| `tests/test_gui_headless.nim` | ✅ 2/2 сьюта | `SearchIndex` интеграция, `AppState` lifecycle |
| `tests/test_adversarial_m5.nim` | ✅ 5/5 стресс-тестов | Буферы >64KB, суррогаты UTF-16, 48-bit MFT, кластеры |
| `tests/test_nimui_layout.nim` (`--mm:orc --threads:on --panics:on`) | ✅ 5/5 сьютов (20 проверок) | Flexbox, HitTest, VirtualList 1M, Signals, 1000-cycle audit (`TrackingAllocator`) |
| `tests/test_nimui_widgets.nim`, `tests/test_nimui_html_css.nim` | ✅ NimUI Widgets & HTML/CSS | Нативные контролы, HTML5/CSS3 subset и `HtmlBindingRegistry` |
| `tests/test_fuzz_mft.nim` | ✅ 100,000 входов | Детерминированный фаззинг `$MFT` парсера (включая границы `$DATA` и `parseRunList`) |
| `tests/test_fuzz_html_css.nim` | ✅ 100,000 входов | Детерминированный фаззинг HTML/CSS парсера, `var()` циклов и JS-валидатора |
| `tests/test_nimui_quickjs.nim` | ✅ 4/4 сьюта QuickJS | Валидатор философии, `Allocator` bridge (`TrackingAllocator`), 30-cycle стресс, Pomodoro |
| `tests/test_safe_compiler.nim` | ✅ 5/5 сьютов `nim_safe` | `--mem-safe`, `--safe-mode`, `--check-safe-atf` + ATF проверка C-кода (требует `nimble build_compiler`) |
| `tests/test_showcase_apps.nim` | ✅ Headless Showcase (4/4) | Headless-сборка (изолированный `--nimcache`) и экспорт 9 PNG всех 4 витринных приложений |
| `apps/nimui_demo/src/main.nim` (`--screenshot`) | ✅ Singularity Lab | Текущее демо на Vulkan 1.1+ (`~5 MB` trimmed WS после `EmptyWorkingSet()`); заменило M14 Raycast `--bench` |

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

## Актуальные результаты бенчмарков CoreX / AlgX vs Rust (`--mm:orc`, idle machine)

Запуск: `nimble bench` (`benchmarks/run_benchmarks.ps1`: 2 прогрева + 11 замеров на простаивающем AMD Ryzen 3 3200U 2C/4T; Nim 2.2.12 `-d:danger --mm:orc -march=native -O3 -flto` MinGW GCC vs Rust 1.96.0 `lto=fat`, `target-cpu=native` MSVC). Подробнее: [`docs/BENCHMARK_SHOWCASE.md`](BENCHMARK_SHOWCASE.md) и [`benchmarks/showcase.html`](../benchmarks/showcase.html).

| Бенчмарк | Реализация | Min (ms) | Med (ms) | Mean (ms) | Max (ms) | Примечание |
|---|---|---|---|---|---|---|
| **UltraSort** (10M `int64`, 4T) | **Nim** (`algx/ultrasort`)<br>**Rust** (`ultra_sort_rust`) | **69.06**<br>75.31 | **71.43**<br>88.60 | **71.75**<br>88.26 | **76.76**<br>104.71 | Nim быстрее ~1.24× по медиане |
| **HashMap** (3M ops, `SplitMix64`) | **Rust** (`RustFastMap / hashbrown`)<br>**Nim** (`FastMap`, 16B SSE2)<br>**Rust** (`std::HashMap`) | **115.53**<br>153.54<br>175.37 | **134.20**<br>168.02<br>219.03 | **135.10**<br>168.74<br>225.78 | **162.21**<br>196.63<br>299.91 | `FastMap` SSE2 ~1.30× быстрее `std::HashMap`; `hashbrown` ~1.25× быстрее `FastMap` |
| **ZeroPack POD** (2M × 32B = 64MB) | **Nim** (`ZeroPack`)<br>**Rust** (`Vec` + `copy_nonoverlapping`) | **12.52**<br>38.63 | **13.69**<br>54.73 | **13.47**<br>50.80 | **13.96**<br>60.78 | Эффект аллокатора (Nim кэширует блоки; MSVC CRT `VirtualAlloc`/`VirtualFree` + page faults) |
| **SimdScan 8-Way** (25M `int64`, 1T) | **Nim** (`algx/simdscan`)<br>**Rust** (`8-Way unsafe`) | **38.66**<br>40.80 | **39.78**<br>43.20 | **40.10**<br>43.71 | **43.85**<br>47.98 | Паритет с небольшим перевесом Nim |

> Оговорки: замеры выполнены на одной 2-ядерной машине за 11 прогонов; сравниваются разные тулчейны (MinGW GCC vs Rust MSVC).

---

## Актуальные результаты бенчмарков NimUI Framework & M14 Microbenchmark

Запуск: `tests/test_nimui_layout.nim` и `apps/nimui_demo/src/main.nim --screenshot ...` (в раннем M14 также использовался `runHeadlessBenchmark` из Raycast Spotlight до замены на Singularity Lab).

| Бенчмарк / Сценарий | Объем / Параметры | Измеренная метрика | Пояснение / Охват | Статус |
|---|---|---|---|---|
| **VirtualList Layout** | 1,000,000 элементов (VirtualList layout + draw pass) | **272.85 µs/frame** | 189 draw instances ($O(1)$ slice vs 1M items) | ✅ Verified (< 500 µs target) |
| **Instant Search (M14 Legacy)** | 100,000 команд/инструментов (SWAR bloom filter) | **0.326 – 1.149 ms** | Только CPU-фильтрация индекса в Raycast Spotlight | ℹ️ Historical M14 |
| **CPU Draw-Instance Build (M14 Legacy)**| 100 кадров (`tree.buildDrawInstances` только на CPU) | **0.020 ms / вызов** | ~50,000 instance-builds/с на CPU (без layout и Vulkan GPU/present) | ℹ️ Historical M14 (< 0.200 ms CPU target) |
| **Trimmed Headless RAM vs Interactive WS** | Headless M14 без Vulkan (`EmptyWorkingSet`) vs Singularity Lab (Vulkan) | **68 KB** (headless trim) / **~5 MB** (Singularity Lab trim) | `EmptyWorkingSet()` вытесняет резидентные страницы в standby; реальный Process Working Set с Vulkan-драйвером выше | ℹ️ Clarified |
| **Idle GPU/CPU Load** | Ожидание событий пользователя (`waitEvents`) | **~0.0% CPU / 0.0% GPU** | Энергосберегающий цикл Win32 (`WaitMessage`) | ✅ Verified (zero idle spinning) |

---

## Исправления и доработки в текущем цикле подготовки v0.1.0 (2026-11-16)

1. **Ядро `corex` & `algx`:**
   - `src/algx/*`: `{.push checks: off.}` перенесено под `when defined(release) or defined(danger):` — debug/тестовые сборки работают с полными проверками границ.
   - `src/corex/testing.nim`: добавлены `orcOccupiedMem()`, `orcHeapDelta()`, `assertZeroOrcLeaks()`, `testWithOrcLeakCheck()`; `testWithLeakCheck` проверяет и `TrackingAllocator`, и ORC-дельту (`GC_fullCollect()` + `getOccupiedMem()`).
   - `src/corex/concurrency.nim` разделён на `src/corex/concurrency/{primitives,pool,parallel}.nim`; глобальные локи переведены на `SpinLock`, добавлены `setDefaultPool` / `hasDefaultPool` и `Result`-API (`trySpawn`, `tryParallelFor`), исключена ловля `Defect`.
   - `src/algx/swissmap.nim` (`FastMap`): обновлён до 16-байтового SSE2-пробирования (`_mm_cmpeq_epi8` / `_mm_movemask_epi8` + SWAR-фоллбэк под `-d:noSse2`).
   - `src/corex/platform/windows/win32_mft.nim`: усилены проверки границ при разборе `$DATA` / `parseRunList` / UTF-16LE и добавлен фаззер `tests/test_fuzz_mft.nim` (100 000 кейсов).
   - `apps/wiztree/types.nim`: исправлена утечка ORC (2,688 байт) в `Tree.=destroy` — добавлено явное уничтожение `frnMap` и `parentFrns`.
2. **`nimui` GPU, окно, контролы, HTML/CSS и QuickJS:**
   - `src/nimui/gpu/font_atlas.nim`: LRU-вытеснение при переполнении атласа, расширение Unicode (Latin-1 + Latin Extended-A/B `U+00A0..U+024F` + кириллица `U+0400..U+04FF`), fallback-шрифты и tofu `U+FFFD`, DPI-масштабирование; уточнено, что текст использует 65-уровневые GDI coverage-битмапы в `R8_UNORM` (не SDF), а SDF применяется для боксов/рамок.
   - `src/nimui/gpu/vulkan_backend.nim` & `window.nim`: обработка `VK_ERROR_DEVICE_LOST`, опциональный `-d:nimuiValidation`, пропуск рендера при свёрнутом окне (`0×0`), `WM_DPICHANGED`, базовая `WM_IME_COMPOSITION`, `clipboard.nim` переведён на `threadvar`.
   - `src/nimui/controls.nim` разделён на `src/nimui/controls/{common,checkbox,radio,slider,dropdown,tooltip}.nim`.
   - `src/nimui/html_css.nim` разделён на `src/nimui/html/{types,parser,cascade,compiler}.nim`; расширены CSS3/HTML5, нестандартные цвета темы вынесены в opt-in `parseThemeColor`, добавлен 100k-фаззер `tests/test_fuzz_html_css.nim`.
3. **Инфраструктура, документация, релизные бинарники и бенчмарки:**
   - Добавлены `LICENSE` (MIT), `CHANGELOG.md`, `CONTRIBUTING.md`, `.github/workflows/ci.yml` (Windows CI + strict warnings), `nimble test_all` / `build_quickjs` / `build_shaders` / `build_release`.
   - Завершена сборка релизных бинарников `nimble build_release` (`PASS`, exit 0):
     - `bin/html_desktop.exe` (`2,001,876 B`)
     - `bin/wiztree.exe` (`475,844 B`)
     - `bin/widget_gallery.exe` (`668,014 B`)
     - `bin/nim_safe.exe` (`8,620,064 B`)
   - Пройдены строгие проверки `nim check --warningAsError[UnusedImport]:on --hintAsError[XDeclaredButNotUsed]:on` на `src/corex.nim`, `src/algx.nim`, `src/nimui.nim` (`exit 0`) и `nim doc --project` для `src/algx.nim` и `src/nimui.nim`.
   - Выполнен итоговый симметричный замер `nimble bench` под `--mm:orc` на простаивающей машине (`Warmup = 2`, `Runs = 11`); результаты и методологические оговорки синхронизированы в `README.md`, `docs/STATE.md`, `docs/BENCHMARK_SHOWCASE.md`, `benchmarks/generate_showcase.py` и `benchmarks/showcase.html`.
   - **Историческая заметка (`apps/nimui_demo`, M14 `runHeadlessBenchmark`):** в исходной M14-версии Raycast Spotlight (до замены на Singularity Lab в `dc90d16`) `0.020 ms` означало CPU-время `buildDrawInstances`, а `68 KB` — память после `EmptyWorkingSet()` без Vulkan. В текущем `apps/nimui_demo` (`Singularity Lab`) используется интерактивный цикл Vulkan 1.1+ и headless-скриншоты `--screenshot`.

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
- **Single-Draw-Call Vulkan 1.1+ UI Архитектура**: Все визуальные примитивы (прямоугольники, скругленные рамки, тени, глифы шрифтов) пакуются в плоский массив 64-байтных POD `UiDrawInstance` и отрисовываются за ровно один вызов `vkCmdDrawIndexed` без смены пайплайнов и аллокаций памяти GPU на кадр.
- **Двухфазная дифференциация dirty-флагов в UiTree**: `isLayoutDirty` (требует пересчета геометрии Flexbox) и `isDirty` (требует только пересборки draw instances). Реактивные биндинги визуальных свойств (`bindBg`) не запускают фазу flexbox-раскладки ($O(1)$ visual reactivity).
- **Связные списки детей на SmallVec**: В `UiNode` список потомков хранится в `SmallVec[UiNodeId, 4]`, что исключает аллокации в куче для подавляющего большинства узлов дерева, где число прямых потомков $\le 4$.
- **$O(1)$ Оконная виртуализация списков (`VirtualList`)**: Для списков произвольного размера (до 1,000,000+ элементов) вычисляется строго видимый срез строк `[firstVis..lastVis]`. Количество создаваемых `UiDrawInstance` не зависит от общего объема данных, гарантируя нулевую деградацию FPS.

---

## Перспективный бэклог и направления развития (после v0.1.0)

1. **Дальнейшее развитие сканера NTFS (`apps/wiztree` & `corex/mft`):**
   - Базовый raw `$MFT` парсер (`parseMftRecord`, FIXUP, runlists, `$ATTRIBUTE_LIST`, hardlink deduplication) и `FSCTL_ENUM_USN_DATA` уже реализованы (M8, M12, M13); в бэклоге — подключение `NtQueryDirectoryFileEx` как промежуточного слоя и расширение CLI/GUI визуализации (treemap).
2. **Кросс-платформенная поддержка и CI (Linux / macOS):**
   - Запуск сьютов на Linux и macOS в CI/CD контейнерах для верификации `posix_fs.nim` (сейчас не проверяется в CI).
   - Портирование `corex/async.nim` (`epoll` / `io_uring` / `kqueue`) и `nimui` windowing/GPU бэкендов (X11/Wayland/Metal/Vulkan) за рамки Windows-first релиза v0.1.0.
3. **Доступность (Accessibility), IME и типографика:**
   - Интеграция с Windows UI Automation (screen readers), расширенная поддержка IME и сложных скриптов (shaping/BiDi/emoji).

