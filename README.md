# Nim Native Ecosystem & NimUI (MVP v0.1.0, Windows-first)

Самодостаточная системная, алгоритмическая и графическая UI-экосистема на **Nim 2.x** (**Windows-first**, без Chromium/WebView2), включающая практическое подмножество HTML5/CSS3 поверх **Vulkan 1.1+ SDF**, опциональный sandboxed движок **QuickJS** и экспериментальный memory-safe компилятор **`nim_safe`**.

Проект сочетает три инженерных принципа:
- **Безопасный высокоуровневый API поверх явного низкоуровневого ядра:** строгие типы ошибок `Result[T, E]` / `Option[T]`, контракт `{.raises: [].}` для пользовательских ошибок (фатальные инварианты и `--panics:on` используют `Defect`), детерминированная память `--mm:orc --threads:on --panics:on` поверх явного низкоуровневого ядра (`cast`/`ptr`/`importc`, `{.push checks: off.}` только в release/danger-сборках `algx` и отключается флагом `-d:algxChecked`), экспериментально проверяемого с помощью `nim_safe` (`--mem-safe` / `--safe-mode` / `--check-safe-atf`). Аудит утечек в `corex`-аллокаторах выполняется через `TrackingAllocator` (`0 bytes leaked`), а управляемая куча ORC (`seq`/`string`/`ref`) проверяется через `GC_fullCollect()` + `getOccupiedMem()` — проверяется тестами [`tests/test_leak_check.nim`](tests/test_leak_check.nim), [`tests/test_ecosystem.nim`](tests/test_ecosystem.nim), [`tests/test_nimui_layout.nim`](tests/test_nimui_layout.nim) и [`tests/test_nimui_quickjs.nim`](tests/test_nimui_quickjs.nim).
- **Явность (в духе Zig):** явная передача аллокаторов (`Allocator`, `Arena`, `Slab[T]`), явная изоляция платформенных слоёв, явный реестр привязок `HtmlBindingRegistry` и явные разрешения возможностей `<script data-caps="...">` без скрытого `eval`.
- **Лаконичность (в духе Python):** декларативный UI DSL на Nim, практическое подмножество HTML5/CSS3 поверх **Vulkan 1.1+ Instanced SDF** (Zero-JS по умолчанию при `allowJs = false`), а также опциональный гибридный слой **QuickJS** (`ui.*`, `Nim.*`).

---

## Архитектура и структура проекта

```text
nim/
├── src/
│   ├── corex.nim / corex/   # Базовый системный слой: память, типы, ОС, сигналы, Unicode
│   ├── algx.nim  / algx/    # Алгоритмы и структуры данных (Radix Sort, SwissTable, SIMD)
│   └── nimui.nim / nimui/   # UI-фреймворк, Flexbox-лейаут, виджеты, HTML5/CSS3, QuickJS и Vulkan SDF
├── compiler/                # Гибридный memory-safe компилятор (--mem-safe, --safe-mode, --check-safe-atf)
├── apps/
│   ├── html_desktop/        # Замена Tauri/Electron: нативный рендер .html на Vulkan 1.1+
│   ├── html_css_studio/     # 4-вкладочная студия HTML5/CSS3, Zero-JS Sandbox и 1M VirtualList
│   ├── widget_gallery/      # Галерея виджетов, SDF-настроек, таблиц и Кириллицы
│   ├── nimui_demo/          # Singularity Lab: релятивистская N-body симуляция + HTML HUD
│   ├── everything/          # Мгновенный поиск файлов по NTFS MFT + USN Journal
│   ├── wiztree/             # Высокопроизводительный анализатор диска через NTFS MFT
│   └── mini-browser/        # Изолированный прототип браузерного пайплайна HTML/CSS -> PNG
├── tests/                   # Модульные, интеграционные и визуальные тесты (TrackingAllocator + ORC)
├── benchmarks/              # Бенчмарки CoreX/AlgX против Rust и генератор HTML-витрины
├── docs/                    # Документация архитектуры, манифест, решения и дорожная карта
├── tools/                   # Вспомогательные инструменты (SPIR-V -> Nim, shaders)
├── nim.cfg                  # Конфигурация компилятора (--mm:orc --threads:on --panics:on)
└── nim_ecosystem.nimble     # Пакет и задачи сборки/тестирования/запуска (MVP v0.1.0)
```

---

## Основные модули

### 1. `src/corex/` — Системное ядро
- `allocators.nim`, `slab.nim`, `memory.nim`, `stringarena.nim`, `testing.nim` — `TrackingAllocator`, арены, `Slab[T]`, строковые арены и контроль утечек (`testWithLeakCheck` проверяет и `TrackingAllocator`, и ORC-дельту через `orcOccupiedMem()` / `assertZeroOrcLeaks()`).
- `result.nim`, `adt.nim`, `traits.nim` — `Result[T, E]`, `Option[T]`, алгебраические типы и явная обработка ошибок без исключений (`{.raises: [].}`).
- `signals.nim` — реактивный DAG-движок (`ReactiveRuntime`, `Signal[T]`, `Computed[T]`, `effect`) без утечек и лишних пересчётов.
- `unicode.nim` — декодирование UTF-8, графемные/руновые утилиты и безопасный рендер Кириллицы и ASCII без `std/unicode`.
- `concurrency.nim` (фасад над `src/corex/concurrency/{primitives,pool,parallel}.nim`), `async.nim`, `workstealing.nim`, `mft.nim`, `fs.nim`, `platform/windows/` — IOCP-реактор, work-stealing пул потоков (`setDefaultPool`/`hasDefaultPool`/`trySpawn`/`tryParallelFor`), прямой парсер NTFS MFT. Глобальное состояние ограничено явными атомарными синглтонами ленивой инициализации (`gDefaultPool` в `pool.nim`, `gDefaultReactor` в `async.nim` на `Atomic[pointer]`).

### 2. `src/algx/` — Высокопроизводительные алгоритмы
*(В debug/тестовых сборках работают полные runtime-проверки границ; `{.push checks: off.}` включается только при `-d:release` или `-d:danger`.)*
- `ultrasort.nim` — гибридный 3-уровневый Cache-Aware MSD Radix Sort + L1 Insertion Sort.
- `swissmap.nim` — плоская хэш-таблица (`FastMap`) с 16-байтовым SSE2-поиском (`_mm_cmpeq_epi8` / `_mm_movemask_epi8`) и 16-байтовым SWAR-фоллбэком (`-d:noSse2`).
- `zeropack.nim` — Zero-Copy POD-сериализация и потоковый JSON.
- `simdscan.nim`, `heap.nim` — 8-канальная векторизованная аналитика массивов и кэш-дружественная куча.

### 3. `src/nimui/` — Графический UI-движок, HTML5/CSS3 и QuickJS Hybrid
- `layout.nim` — быстрый O(N) Flexbox-движок (`LayoutPool`, `UiTree`, `UiNode`) с кэшем измерения текста и поддержкой прокрутки (`clipChildren`).
- `controls.nim` (фасад над `controls/{common,checkbox,radio,slider,dropdown,tooltip}.nim`), `dsl.nim`, `multiline.nim`, `clipboard.nim` (потоково-локальный контекст `gThreadClipboard` / `ClipboardContext` в `{.threadvar.}`) — декларативный DSL (`Box`, `VStack`, `HStack`, `Text`, `Button`, `TextInput`, `VirtualList` на 1 000 000+ строк) и нативные виджеты: `Checkbox`, `RadioGroup`, `Slider`, `Dropdown`, `Tooltip`, многострочный `TextArea`.
- `html_css.nim` (фасад над `src/nimui/html/{types,parser,cascade,compiler}.nim`) — встроенный парсер практического подмножества HTML5 и каскада CSS3, Zero-JS санитайзер (`allowJs = false` по умолчанию) и компилятор HTML-документов прямо в `UiTree` с реактивной привязкой к Nim через `HtmlBindingRegistry`.
- `js/js_validator.nim`, `js/js_engine.nim`, `js/html_js_bridge.nim`, `js/qjs_bridge.c` — опциональный встроенный движок **QuickJS** (активируется при `allowJs = true`), маршрутизирующий всю память через `corex/allocators.Allocator` (`TrackingAllocator`: `0 bytes leaked`, проверяется в [`tests/test_nimui_quickjs.nim`](tests/test_nimui_quickjs.nim)), со статическими/рантайм-проверками (запрет `var`, `==`/`!=`, `eval`/`Function`/`with`/`__proto__`, лимиты памяти/стека/шагов; явные `data-caps="dom,timers,nim,console"`; `ui.*` и `Nim.*` API).
- `gpu/vulkan_backend.nim`, `gpu/font_atlas.nim`, `gpu/shaders.nim`, `rasterizer.nim`, `window.nim` — аппаратный бэкенд **Vulkan 1.1+ (Instanced SDF для боксов/рамок)** за один `vkCmdDrawIndexed`, атлас глифов (Win32 GDI `GetGlyphOutlineW`, 65-уровневые coverage-битмапы — текст не SDF; LRU-вытеснение, tofu-глиф `U+FFFD`, масштабирование по DPI) и детерминированный **CPU Software Rasterizer** для headless-тестов и экспорта PNG.

### 4. `compiler/` — Экспериментальный гибридный Memory-Safe компилятор (`bin/nim_safe.exe`)
- `nim_safe.nim`, `safety_config.nim` — обёртка поверх компилятора Nim 2.2.12 с флагами `--mem-safe`, `--safe-mode`, `--check-safe-atf` и `--atf-report:<path>`, принудительно включающая `--mm:orc`, `--threads:on`, `--threadAnalysis:on`, `--panics:on`, runtime checks и `strictFuncs`.
- `mem_safe_pass.nim` — AST/семантический проход безопасности: запрещает `cast` (`[MEM-SAFE-001]`), сырые `ptr`/`pointer` (`[MEM-SAFE-002]`), сырые `alloc`/`dealloc`/`copyMem` (`[MEM-SAFE-003]`), `{.emit.}` (`[MEM-SAFE-004]`), мутабельные глобалы (`[MEM-SAFE-005]`), утечки стековых адресов (`[MEM-SAFE-006]`), выполняет borrow checking через `varpartitions` и требует `{.raises: [].}` + `Result[T, E]` в `--safe-mode` (`[SAFE-MODE-001/002]`). Разрешает явно размеченный `{.trustedUnsafe.}` / `block trustedUnsafe:`.
- `atf_c_checker.nim` — **After-Codegen-Finish (ATF)** верификатор сгенерированного C-кода (`--check-safe-atf`), проверяющий `.c` файлы до вызова GCC на запрещённые небезопасные вызовы CRT (`malloc`/`free`/`strcpy` и др., `[ATF-001]`), сырую арифметику указателей (`[ATF-002]`), корректность ORC-хуков (`[ATF-003]`), возврат адресов стека (`[ATF-004]`) и наличие проверок границ/переполнения (`[ATF-005]`).

---

## Витринные приложения (Showcase MVP)

### 1. `apps/html_desktop` — Нативный HTML/CSS Desktop Runner (альтернатива Tauri/Electron для подмножества HTML/CSS)
Рендерит автономные `.html` файлы (по умолчанию [`apps/html_desktop/ui/showcase.html`](apps/html_desktop/ui/showcase.html)) напрямую через **Vulkan 1.1+ SDF** без Chromium, WebView2 и Node.js. Логика и обработчики пишутся на чистом Nim (`HtmlBindingRegistry`) или на опциональном sandboxed QuickJS (`--allow-js` / `--pomodoro`).

Поддерживает флаг `--file <путь.html>` для загрузки произвольных `.html` страниц (Zero-JS по умолчанию, либо с `--allow-js`), а также headless-экспорт PNG (`--headless-test --screenshot <out.png>`).

### 2. `apps/html_css_studio` — HTML5/CSS3 Zero-JS Studio
Интерактивная студия с 4 вкладками:
1. Дашборд телеметрии и KPI;
2. Реактивные формы и нативные контролы (`TextInput`, `Slider`, `Checkbox`, `Dropdown`);
3. **Zero-JS Security Sandbox** — живая демонстрация блокировки `<script>`, `onclick="..."` и `javascript:`;
4. Виртуальный обозреватель на **1 000 000 записей** через `VirtualList`.

### 3. `apps/widget_gallery` — Галерея виджетов, SDF и Unicode
Настройка параметров SDF-боксов в реальном времени (`border-radius`, `border-width`, `softness`, палитры), ввод Кириллицы + ASCII в `TextInput` / `TextArea`, `Checkbox`, `RadioGroup`, `Slider`, `Dropdown`, `Tooltip` и скролл со scissor-обрезкой.

### 4. `apps/nimui_demo` — Singularity Lab
Релятивистская N-body симуляция аккреционного диска черной дыры Керра с гибридным HUD-интерфейсом на базе `html_css`.

### Скриншоты (Headless Preview)

| `apps/widget_gallery` (Виджеты, SDF и Кириллица) | `apps/nimui_demo` (Singularity Lab) |
| :---: | :---: |
| ![Widget Gallery Preview](apps/widget_gallery/widget_gallery_preview.png) | ![Singularity Lab Preview](apps/nimui_demo/singularity_lab_preview.png) |
| [`apps/widget_gallery/widget_gallery_preview.png`](apps/widget_gallery/widget_gallery_preview.png) | [`apps/nimui_demo/singularity_lab_preview.png`](apps/nimui_demo/singularity_lab_preview.png) |

---

## Быстрый старт

### Требования и поддерживаемые платформы
- **Платформа (Windows-first в v0.1.0):** **Windows 10/11 (x64)**. Для интерактивных окон нужен драйвер и GPU с поддержкой **Vulkan 1.1+** (`vulkan-1.dll`); headless-тесты и генерация PNG работают на любом CPU через программный SDF-растеризатор. Поддержка Linux/macOS (`corex/platform/posix/posix_fs.nim` не верифицирован в CI, а `corex/async.nim` и `nimui` сейчас ориентированы на Windows) находится в **бэклоге**.
- **Инструментарий:** **Nim `>= 2.0`** (проверено на `2.2.12`) + компилятор C (MinGW-W64 GCC `11.1.0` / Clang) в `PATH`. Для генерации HTML-витрины бенчмарков нужен `python`, для сборки статической библиотеки QuickJS (`src/nimui/js/libquickjs.a`, не отслеживается в git) — `powershell -ExecutionPolicy Bypass -File tools/build_quickjs.ps1`, для пересборки шейдеров — `tools/glslang`.

### Запуск приложений через Nimble

```powershell
# 1. Загрузить showcase.html или отладочный Pomodoro таймер (1–3 сек, Nim + QuickJS)
nimble html_desktop
nimble pomodoro

# Или открыть собственный .html файл (Zero-JS или с --allow-js):
nim c -r apps/html_desktop/src/main.nim --file path/to/your_ui.html

# Сборка и запуск гибридного memory-safe компилятора:
nimble build_compiler
bin/nim_safe.exe c -r --mem-safe --safe-mode --check-safe-atf tests/fixtures/safe_compiler/safe_valid.nim

# 2. HTML5/CSS3 Zero-JS Studio (4 вкладки + VirtualList 1M)
nimble studio

# 3. Галерея нативных виджетов, SDF и Кириллицы
nimble gallery

# 4. Singularity Lab (симуляция черной дыры Керра + HTML HUD)
nimble demo

# 5. Системные утилиты (NTFS MFT)
nimble wiztree
nim c -r apps/everything/src/cli.nim
```

### Снятие headless-скриншотов (без окна GPU)

```powershell
nim c -r apps/html_desktop/src/main.nim --headless-test --screenshot desktop_initial.png --screenshot-interactive desktop_clicked.png
nim c -r apps/html_css_studio/src/main.nim --headless-test --export-screenshots screenshots_out
nim c -r apps/widget_gallery/src/main.nim --headless-test --screenshot gallery.png
nim c -r apps/nimui_demo/src/main.nim --screenshot singularity.png
```

### Запуск тестов

```powershell
# Полный прогон всех сьютов (38+ тестов, включает автосборку libquickjs.a и nim_safe.exe)
nimble test_all

# Базовые системные тесты CoreX / AlgX / MFT / Signals / IOCP
nimble test

# Полный набор тестов NimUI (Layout, Widgets, HTML5/CSS3) и QuickJS
nimble test_ui
nimble test_js

# Верификация экспериментального memory-safe компилятора (--mem-safe, --safe-mode, --check-safe-atf)
nimble test_compiler

# Проверка всех 4 витринных приложений в headless-режиме + генерация скриншотов
nimble test_showcase

# Фаззинг-тесты (100 000 входов каждый): MFT и HTML/CSS/JS
nim c -r tests/test_fuzz_mft.nim
nim c -r tests/test_fuzz_html_css.nim

# Негативная и позитивная проверка детекторов утечек (TrackingAllocator + ORC)
nim c -r tests/test_leak_check.nim

# Бенчмарки против Rust (генерирует benchmarks/showcase.html; машина-специфично, не в CI)
nimble bench
nimble showcase_html
```

---

## Бенчмарки CoreX + AlgX против Rust (`--mm:orc`, машина-специфично, не в CI)

Симметричное сравнение (`Warmup = 2`, `Runs = 11`, простаивающая машина AMD Ryzen 3 3200U 2C/4T, Windows x64; результаты привязаны к конкретному железу и не запускаются как CI-гейт): **Nim 2.2.12** (`-d:danger --mm:orc -march=native -O3 -flto`, MinGW GCC `11.1.0`) против **Rust 1.96.0** (`lto=fat`, `target-cpu=native`, MSVC / LLVM `22.1.2`).

| Дисциплина | Реализация | Min (мс) | Median (мс) | Mean (мс) | Max (мс) |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **UltraSort** (10M `int64`, 4T) | **Nim** (`algx/ultrasort`)<br>**Rust** (`ultra_sort_rust`) | **69.06**<br>75.31 | **71.43**<br>88.60 | **71.75**<br>88.26 | **76.76**<br>104.71 |
| **HashMap** (3M ops, `SplitMix64`) | **Rust** (`RustFastMap / hashbrown`)<br>**Nim** (`FastMap`, 16B SSE2)<br>**Rust** (`std::HashMap`) | **115.53**<br>153.54<br>175.37 | **134.20**<br>168.02<br>219.03 | **135.10**<br>168.74<br>225.78 | **162.21**<br>196.63<br>299.91 |
| **ZeroPack POD** (2M × 32B = 64MB) | **Nim** (`ZeroPack`)<br>**Rust** (`Vec` + `copy_nonoverlapping`) | **12.52**<br>38.63 | **13.69**<br>54.73 | **13.47**<br>50.80 | **13.96**<br>60.78 |
| **SimdScan 8-Way** (25M `int64`, 1T) | **Nim** (`algx/simdscan`)<br>**Rust** (`8-Way unsafe`) | **38.66**<br>40.80 | **39.78**<br>43.20 | **40.10**<br>43.71 | **43.85**<br>47.98 |

> **Методологические оговорки:** (1) все замеры выполнены на одной 2-ядерной машине за 11 прогонов без межмашинных доверительных интервалов; (2) сравниваются разные тулчейны (MinGW GCC vs Rust MSVC); (3) преимущество Nim в `ZeroPack POD` обусловлено эффектом аллокатора (Nim переиспользует блоки 64 МБ, тогда как временный `Vec` в MSVC CRT на каждой итерации вызывает `VirtualAlloc`/`VirtualFree` и soft page faults); (4) `FastMap` (16B SSE2) опережает `std::HashMap` в **~1.30× по медиане**, но уступает `hashbrown` (**~1.25×** в пользу `hashbrown`). Подробности — в [`docs/BENCHMARK_SHOWCASE.md`](docs/BENCHMARK_SHOWCASE.md) и [`benchmarks/showcase.html`](benchmarks/showcase.html).

---

## Поддерживаемые возможности HTML5 / CSS3 (практическое подмножество) и QuickJS Hybrid (`src/nimui/html_css.nim`, `src/nimui/js/`)

| Категория | Поддержка в MVP v0.1.0 |
| :--- | :--- |
| **HTML-теги** | `html`, `body`, `div`, `section`, `header`, `footer`, `nav`, `main`, `aside`, `article`, `h1`–`h3`, `p`, `span`, `label`, `strong`, `em`, `a`, `button`, `input` (`type="text"` / `hidden`, `value`, `placeholder`), `textarea`, `select`/`option`, `ul`/`ol`/`li` (`list-style`), `table`/`thead`/`tbody`/`tr`/`th`/`td`, `img`, `br`, `hr`, `svg` (`viewBox` bounding box), `head`, `style`, `meta`, `link`, `title` |
| **CSS-селекторы и `@`-правила** | `*`, по тегу (`div`), `#id`, `.class`, комбинированные (`div.card`), потомки (`.row .btn`, `.row > .btn`), `:root`, `:hover`, `:active`, `:focus`, `:disabled` (стиль + блокировка обработчиков), `@media` (`min/max-width`, `min/max-height`, `prefers-color-scheme`) |
| **Раскладка (Layout)** | `display`: `flex`, `block`, `inline`, `inline-block`, `none`; `flex-direction`, `flex-wrap`, `justify-content`, `align-items`, `align-self`, `flex-grow`, `flex-shrink`, `flex-basis`, `flex`, `width`/`height` (`px`, `%`), `min-width`/`max-width`, `min-height`/`max-height`, `margin` (+ `-top/right/bottom/left`, `auto`), `padding` (+ `-top/right/bottom/left`), `gap`, `row-gap`, `column-gap`, `position`, `z-index`, `overflow`/`overflow-y`, `text-align` |
| **Визуальный стиль (SDF)** | `color`, `background`/`background-color`, `linear-gradient(...)`, hex `#RGB`/`#RGBA`/`#RRGGBB`/`#RRGGBBAA`, `rgb()`/`rgba()`, `hsl()`/`hsla()`, стандартные именованные CSS-цвета (плюс opt-in тема `parseThemeColor` / `NimUiThemePaletteCss`), `var(--x)` с fallback, `opacity`, `box-shadow`, `border`/`border-width`/`border-color`/`border-radius`, `font-size`, `font-weight`, `font-family`, `line-height`, `cursor`, `text-overflow`, `white-space`, `transition` |
| **Реактивность Nim (`data-*`)** | `data-click` (`HtmlClickProc`), `data-text` / `data-bind` (`Signal[string]` или `HtmlTextProc`), `data-model` / `data-bind` (`Signal[string]` двусторонняя привязка `<input>`), `data-input` (`HtmlInputProc`) |
| **Режим Zero-JS vs QuickJS** | По умолчанию (`allowJs = false`): строгий отказ (`Result.err`) при `<script>`, любых `on*`-атрибутах (`onclick`, `onload` и т.д.) и `javascript:` URI. При `allowJs = true` (`HtmlJsSession`): встроенный **QuickJS** с запретом `var`/`==`/`!=`/`eval`/`Function`/`with`/`__proto__`, лимитами памяти (8 MB), стека (512 KB) и шагов (250k) и явными `<script data-caps="dom,timers,nim,console">` |

### Справочник API привязок (`HtmlBindingRegistry` и `data-*`)

Модули [`src/nimui/html_css.nim`](src/nimui/html_css.nim) и [`src/nimui/js/html_js_bridge.nim`](src/nimui/js/html_js_bridge.nim) предоставляют явный реестр привязок без рефлексии:

- **Типы колбэков (`html_css.nim`):**
  - `HtmlClickProc* = proc() {.closure, gcsafe, raises: [].}`
  - `HtmlInputProc* = proc(text: string) {.closure, gcsafe, raises: [].}`
  - `HtmlTextProc* = proc(): string {.closure, gcsafe, raises: [].}`
- **Реестр `HtmlBindingRegistry` (`html_css.nim`):**
  - `initHtmlBindingRegistry*(): HtmlBindingRegistry` / `destroy*(reg: var HtmlBindingRegistry)`
  - `onClick*(reg: var HtmlBindingRegistry, name: string, cb: HtmlClickProc)` — связывается с атрибутом `data-click="<name>"`
  - `onInput*(reg: var HtmlBindingRegistry, name: string, cb: HtmlInputProc)` — связывается с `data-input="<name>"` (для `<input>`)
  - `bindTextSignal*(reg: var HtmlBindingRegistry, name: string, sig: Signal[string])` и `bindText*(reg, name, sig)` / `bindText*(reg, name, fn: HtmlTextProc)` — связываются с `data-text="<name>"` (или fallback `data-bind="<name>"`)
  - `bindInputSignal*(reg: var HtmlBindingRegistry, name: string, sig: Signal[string])` — двусторонняя привязка `<input>` через `data-bind="<name>"` или `data-model="<name>"`
  - `getNodeById*(reg: HtmlBindingRegistry, id: string): Option[SlabId]` — поиск `SlabId` по HTML `id="..."`
- **Монтирование и QuickJS-мост:**
  - `parseHtmlDoc*(html: string, allowJs: bool = false): Result[HtmlDoc, string]`
  - `mountHtml*(tree: var UiTree, rt: ptr ReactiveRuntime, doc: HtmlDoc, sheet: CssStylesheet, bindings: var HtmlBindingRegistry, parentId: SlabId = SlabId(-1)): Result[SlabId, string]`
  - `mountHtmlString*(tree: var UiTree, rt: ptr ReactiveRuntime, html, extraCss: string, bindings: var HtmlBindingRegistry, parentId: SlabId = SlabId(-1)): Result[SlabId, string]`
  - `initHtmlJsSession*(alloc: Allocator, tree: var UiTree, rt: var ReactiveRuntime, bindings: var HtmlBindingRegistry, cfg: QuickJsConfig = defaultQuickJsConfig()): Result[HtmlJsSession, string]`
  - `registerNimFunc*(s: var HtmlJsSession, name: string, fn: NimJsHostProc)` (`NimJsHostProc* = proc(arg1, arg2: string): string {.closure, gcsafe, raises: [].}`), `mountHtmlWithJs*(s: var HtmlJsSession, html: string, extraCss: string = "", parentId: SlabId = SlabId(-1'i32)): Result[SlabId, string]`, `tick*(s: var HtmlJsSession, dtMs: int): Result[int, string]`
  - JS-способности в `<script data-caps="...">`: `dom` (`document.getElementById`, `document.querySelector`, `ui.*`), `timers` (`setTimeout`/`setInterval`/`clearTimeout`/`clearInterval`), `nim` (`Nim.call`, `Nim.get`, `Nim.set`), `console` (`console.log/warn/error`), а также `all` / `none` (при пустом `data-caps` по умолчанию даются `{jcDom, jcConsole}`).

---

## Поддерживается / Не поддерживается (сводная матрица v0.1.0)

| Область | Поддерживается | Не поддерживается / Ограничения |
| :--- | :--- | :--- |
| **CSS / HTML5** | Flexbox (`flex`, `flex-direction`, `flex-wrap`, `justify-content`, `align-items`, `gap`, `margin`, `padding`), селекторы (`*`, tag, `#id`, `.class`, потомки `>`/` `, `:root`, `:hover`, `:active`, `:focus`, `:disabled`), `@media`, `var(--x)` с fallback, `linear-gradient`, `box-shadow`, `border-radius`, `transition`, стандартные именованные CSS-цвета, hex/`rgb`/`hsl`. | CSS Grid, `float`, браузерный табличный layout, `@keyframes`, `calc()`, `fetch`, `<script src="...">`. Нестандартные цвета темы (`slate`, `indigo`, `emerald`, `rose`, `amber`, `obsidian`, `midnight`) отключены в обычном CSS и доступны только как **opt-in** через `parseThemeColor` (`src/nimui/html/cascade.nim`). |
| **Платформы** | **Windows 10/11 (x64)**: полный цикл (Vulkan 1.1+, IOCP, MFT, `nim_safe`, все тесты и CI).<br>**Ubuntu Linux (CI)**: компиляционная проверка `nim check` для `src/corex.nim` и `src/algx.nim`. | Полноценный runtime/CI для `nimui` (windowing/Vulkan/GDI), `corex/async.nim` (IOCP) и `corex/mft.nim` на Linux/macOS; `src/corex/platform/posix/posix_fs.nim` не верифицирован в runtime CI. |
| **Шрифты и рендеринг текста** | На Windows: **GDI `GetGlyphOutlineW`** (`GGO_GRAY8_BITMAP`, 65-уровневые coverage-битмапы в `1024×1024 R8_UNORM` атласе) для ASCII, Latin-1/Extended-A/B (`U+00A0..U+024F`), кириллицы (`U+0400..U+04FF`), fallback-шрифты, tofu `U+FFFD`, LRU-вытеснение, Per-Monitor v2 DPI (`WM_DPICHANGED` → `rebuildForDpi`). | **Текст не использует SDF** (аналитический SDF в `ui.frag` применяется только к боксам/рамкам). Крупные числа **64+pt** выглядят мягче, так как атлас растеризуется на `baseSize` (по умолчанию `32px * dpiScale`) и билинейно масштабируется (`fontSize / baseSize`). Нет HarfBuzz/BiDi/Arabic/Indic shaping и цветных emoji (`COLR`/`sbix`). |
| **IME и доступность** | Базовая обработка `WM_IME_COMPOSITION` (UTF-16 → UTF-8 вставка скомпонованного текста в `TextInput` / `TextArea`). | Inline-окно кандидатов IME (позиционирование/предпросмотр композиции), системное дерево доступности (Windows UI Automation / screen readers). |

---

## Ограничения (Limitations)

1. **Windows-first в v0.1.0:**
   - Интерактивное окно (`src/nimui/window.nim`), асинхронный IOCP-рантайм (`src/corex/async.nim`) и парсер MFT (`src/corex/mft.nim` / `win32_mft.nim`) рассчитаны на Windows x64.
   - `src/corex/platform/posix/posix_fs.nim` предоставлен как заготовка для POSIX, но **не верифицирован в CI**; полноценная поддержка Linux и macOS вынесена в бэклог.
2. **Права администратора для прямого чтения `$MFT` (`apps/wiztree`, `corex/mft`):**
   - Прямой потоковый доступ к тому `\\.\<drive>:` через `FSCTL_ENUM_USN_DATA` (`scanMftDirect` в [`apps/wiztree/scanner.nim`](apps/wiztree/scanner.nim)) и сырые чтения `$MFT` требуют **прав Администратора** и файловой системы NTFS.
   - При отсутствии прав администратора (или для не-NTFS томов / отдельных подпапок) `scanVolume` прозрачно переключается на fallback `scanWin32Fast` (пакетный обход через `FindFirstFileExW` + `FindExInfoBasic` + `FIND_FIRST_EX_LARGE_FETCH` в `corex/fs`), который работает под обычным пользователем, но медленнее прямого чтения MFT.
3. **Требование Vulkan 1.1+ GPU:**
   - Интерактивный рендер `nimui` динамически загружает `vulkan-1.dll` и требует драйвер и GPU с поддержкой **Vulkan 1.1+**. При отсутствии Vulkan GPU работают только headless-сценарии и экспорт PNG на базе CPU-растеризатора (`src/nimui/rasterizer.nim`).
   - Устойчивость: `VK_ERROR_DEVICE_LOST` обрабатывается явно (`recoverFromDeviceLost` / `renderInstancesResult`), свёрнутое окно (`IsIconic`, 0×0 swapchain) пропускает рендер, слои валидации Vulkan включаются опционально (`-d:nimuiValidation`, требуется установленный `VK_LAYER_KHRONOS_validation`). Полное восстановление после потери устройства не гарантируется на всех драйверах — при сбое приложение завершает рендер без падения/зависания.
4. **Границы HTML5/CSS3 и QuickJS:**
   - `html_css` реализует практическое подмножество HTML/CSS поверх `UiTree` Flexbox-движка — это **не** полноценный браузерный движок (отсутствуют CSS Grid, `float`, табличный layout уровня браузеров, Web Audio/Canvas/DOM Range, `fetch`, внешние `<script src="...">`).
   - QuickJS-слой опционален (`allowJs = true`), допускает только встроенные `<script>` с явными `data-caps` и строгим подмножеством JS без `eval`/`var`/`==`/`__proto__`.
5. **Шрифты, IME и доступность (Accessibility):**
   - Растеризация шрифтов на Windows выполняется через GDI `GetGlyphOutlineW` (65-уровневые coverage-битмапы, не SDF) в фиксированный 1024×1024 `R8_UNORM` атлас (`src/nimui/gpu/font_atlas.nim`; для не-Windows — минимальный fallback-генератор). Покрытие: ASCII, Latin-1/Latin Extended-A/B (`U+00A0..U+024F`), кириллица `U+0400..U+04FF`, UI-символы; при заполнении атласа выполняется LRU-вытеснение, для отсутствующих глифов используется fallback-шрифт (`Segoe UI Symbol`, `Microsoft YaHei`, `Malgun Gothic`) и tofu-глиф `U+FFFD`. Сложный text shaping (HarfBuzz/Arabic/Indic BiDi), цветные emoji (COLR/sbix) и системное дерево доступности (Windows UI Automation / screen readers) в v0.1.0 отсутствуют; IME — базовая поддержка `WM_IME_COMPOSITION` (UTF-16 → UTF-8), без inline-кандидатов. Per-Monitor v2 DPI (`WM_DPICHANGED`) пробрасывается в растеризацию глифов и layout.
6. **Пересборка SPIR-V шейдеров (`tools/glslang` + `tools/spv_to_nim.nim`):**
   - В репозитории хранятся GLSL-исходники ([`tools/shaders/ui.vert`](tools/shaders/ui.vert), [`tools/shaders/ui.frag`](tools/shaders/ui.frag)), предсобранные бинарники `.spv` и сгенерированный Nim-массив [`src/nimui/gpu/shaders.nim`](src/nimui/gpu/shaders.nim).
   - Если вы меняете шейдеры, установите `glslangValidator` в `tools/glslang/` (каталог в `.gitignore`) и выполните:
     ```powershell
     tools\glslang\glslangValidator.exe -V tools/shaders/ui.vert -o tools/shaders/ui.vert.spv
     tools\glslang\glslangValidator.exe -V tools/shaders/ui.frag -o tools/shaders/ui.frag.spv
     nim c -r tools/spv_to_nim.nim
     ```

---

## Генерация API-документации (`nim doc`)

Для локальной генерации HTML-документации по исходным модулям (каталог `htmldocs/` добавлен в `.gitignore`):

```powershell
# Полная проектная документация с индексом (проверено: exit 0)
nim doc --project --index:on --outdir:htmldocs src/corex.nim
nim doc --project --index:on --outdir:htmldocs src/algx.nim
nim doc --project --index:on --outdir:htmldocs src/nimui.nim
```

> **Языковая заметка по документации:** `README.md`, [`docs/STATE.md`](docs/STATE.md), [`docs/BENCHMARK_SHOWCASE.md`](docs/BENCHMARK_SHOWCASE.md), [`docs/NIM_ROADMAP_FEATURES.md`](docs/NIM_ROADMAP_FEATURES.md) и [`docs/MANUAL_CHECKLIST.md`](docs/MANUAL_CHECKLIST.md) ведутся на русском языке; архитектурные спецификации [`docs/MANIFEST.md`](docs/MANIFEST.md), [`docs/PROJECT.md`](docs/PROJECT.md) и [`docs/DECISIONS.md`](docs/DECISIONS.md) ведутся на английском языке.

---

## Дополнительная документация

Подробные проектные материалы перенесены в каталог [`docs/`](docs/):
- [`docs/PROJECT.md`](docs/PROJECT.md) — обзор архитектуры и подсистем.
- [`docs/MANIFEST.md`](docs/MANIFEST.md) — философский и технический манифест экосистемы.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — журнал архитектурных решений.
- [`docs/STATE.md`](docs/STATE.md) — состояние модулей и спринтов.
- [`docs/MANUAL_CHECKLIST.md`](docs/MANUAL_CHECKLIST.md) — ручной чек-лист аппаратных и интерактивных проверок (Vulkan device lost, minimize `0×0`, DPI, IME, права администратора `$MFT`).
- [`docs/BENCHMARK_SHOWCASE.md`](docs/BENCHMARK_SHOWCASE.md) — методика и результаты сравнения `CoreX`/`AlgX` с Rust.
- [`docs/NIM_ROADMAP_FEATURES.md`](docs/NIM_ROADMAP_FEATURES.md) — дорожная карта развития.

---

## Лицензия и сторонние компоненты

- Основной код проекта распространяется под лицензией **MIT** (см. [`LICENSE`](LICENSE)).
- Встроенный движок **QuickJS Javascript Engine** (`src/nimui/js/vendor/`, версия `2026-06-04`, Copyright (c) 2017-2025 Fabrice Bellard, Charlie Gordon) распространяется под лицензией **MIT** — см. [`src/nimui/js/vendor/LICENSE`](src/nimui/js/vendor/LICENSE) и [`src/nimui/js/vendor/README.md`](src/nimui/js/vendor/README.md).

