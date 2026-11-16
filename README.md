# Nim Native Ecosystem & NimUI (MVP v0.1.0)

Самодостаточная системная, алгоритмическая и графическая UI-экосистема на чистом **Nim 2.x** без внешних C/C++ UI/рендер-фреймворков, Chromium/WebView2 и JavaScript.

Проект сочетает три инженерных принципа:
- **Безопасность (как в Rust):** строгие типы ошибок `Result[T, E]` / `Option[T]`, контракт `{.raises: [].}`, детерминированная память `--mm:orc --threads:on --panics:on` и автоматический аудит утечек через `TrackingAllocator` (`0 bytes leaked`).
- **Явность (как в Zig):** явная передача аллокаторов (`Allocator`, `Arena`, `Slab[T]`), отсутствие скрытых глобальных состояний, явный реестр привязок `HtmlBindingRegistry` и явные разрешения возможностей `<script data-caps="...">` без скрытого `eval`.
- **Простота (как в Python):** лаконичный декларативный UI DSL на Nim, нативный HTML5/CSS3 рендеринг поверх **Vulkan 1.1+ Instanced SDF**, а также опциональный гибридный слой **QuickJS** (`ui.*`, `Nim.*`) с проверками в духе философии проекта.

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
├── tests/                   # Модульные, интеграционные и визуальные тесты (0 leaks)
├── benchmarks/              # Бенчмарки CoreX/AlgX против Rust и генератор HTML-витрины
├── docs/                    # Документация архитектуры, манифест, решения и дорожная карта
├── tools/                   # Вспомогательные инструменты (SPIR-V -> Nim, shaders)
├── nim.cfg                  # Конфигурация компилятора (--mm:orc --threads:on --panics:on)
└── nim_ecosystem.nimble     # Пакет и задачи сборки/тестирования/запуска (MVP v0.1.0)
```

---

## Основные модули

### 1. `src/corex/` — Системное ядро
- `allocators.nim`, `slab.nim`, `memory.nim`, `stringarena.nim` — `TrackingAllocator`, арены, `Slab[T]`, строковые арены и контроль фрагментации.
- `result.nim`, `adt.nim`, `traits.nim` — `Result[T, E]`, `Option[T]`, алгебраические типы и явная обработка ошибок без исключений (`{.raises: [].}`).
- `signals.nim` — реактивный DAG-движок (`ReactiveRuntime`, `Signal[T]`, `Computed[T]`, `effect`) без утечек и лишних пересчётов.
- `unicode.nim` — декодирование UTF-8, графемные/руновые утилиты и безопасный рендер Кириллицы и ASCII без `std/unicode`.
- `async.nim`, `workstealing.nim`, `mft.nim`, `fs.nim`, `platform/windows/` — IOCP-реактор, work-stealing пул потоков, прямой парсер NTFS MFT.

### 2. `src/algx/` — Высокопроизводительные алгоритмы
- `ultrasort.nim` — гибридный 3-уровневый Cache-Aware MSD Radix Sort + L1 Insertion Sort.
- `swissmap.nim` — быстрая плоская хэш-таблица (`FastMap`).
- `zeropack.nim` — Zero-Copy POD-сериализация и потоковый JSON.
- `simdscan.nim`, `heap.nim` — 8-канальная векторизованная аналитика массивов и кэш-дружественная куча.

### 3. `src/nimui/` — Графический UI-движок, HTML5/CSS3 и QuickJS Hybrid
- `layout.nim` — быстрый O(N) Flexbox-движок (`LayoutPool`, `UiTree`, `UiNode`) с кэшем измерения текста и поддержкой прокрутки (`clipChildren`).
- `controls.nim`, `dsl.nim`, `multiline.nim`, `clipboard.nim` — декларативный DSL (`Box`, `VStack`, `HStack`, `Text`, `Button`, `TextInput`, `VirtualList` на 1 000 000+ строк) и нативные виджеты: `Checkbox`, `RadioGroup`, `Slider`, `Dropdown`, `Tooltip`, многострочный `TextArea`.
- `html_css.nim` — встроенный парсер HTML5 и каскада CSS3, Zero-JS санитайзер (`allowJs = false` по умолчанию) и компилятор HTML-документов прямо в `UiTree` с реактивной привязкой к Nim через `HtmlBindingRegistry`.
- `js/js_validator.nim`, `js/js_engine.nim`, `js/html_js_bridge.nim`, `js/qjs_bridge.c` — встроенный движок **QuickJS**, маршрутизирующий всю память через `corex/allocators.Allocator` (`0 bytes leaked`), со статическими/рантайм-проверками философии проекта (Rust: запрет `var`, `==`/`!=`, `eval`/`Function`/`with`/`__proto__`, лимит памяти, стека и шагов; Zig: явные `data-caps="dom,timers,nim,console"`; Python: `ui.*` и `Nim.*` API), позволяющий писать логику как на Nim, так и на JavaScript.
- `gpu/vulkan_backend.nim`, `gpu/font_atlas.nim`, `gpu/shaders.nim`, `rasterizer.nim`, `window.nim` — аппаратный бэкенд **Vulkan 1.1+ (Instanced SDF)** за минимальное число Draw Call, LRU-атлас глифов (GDI/ClearType с фолбэком) и детерминированный **CPU Software Rasterizer** для headless-тестов и экспорта PNG.

### 4. `compiler/` — Гибридный Memory-Safe компилятор (`bin/nim_safe.exe`)
- `nim_safe.nim`, `safety_config.nim` — обёртка поверх компилятора Nim 2.2.12 с флагами `--mem-safe`, `--safe-mode`, `--check-safe-atf` и `--atf-report:<path>`, принудительно включающая `--mm:orc`, `--threads:on`, `--threadAnalysis:on`, `--panics:on`, runtime checks и `strictFuncs`.
- `mem_safe_pass.nim` — AST/семантический проход безопасности: запрещает `cast` (`[MEM-SAFE-001]`), сырые `ptr`/`pointer` (`[MEM-SAFE-002]`), сырые `alloc`/`dealloc`/`copyMem` (`[MEM-SAFE-003]`), `{.emit.}` (`[MEM-SAFE-004]`), мутабельные глобалы (`[MEM-SAFE-005]`), утечки стековых адресов (`[MEM-SAFE-006]`), выполняет borrow checking через `varpartitions` и требует `{.raises: [].}` + `Result[T, E]` в `--safe-mode` (`[SAFE-MODE-001/002]`). Разрешает явно размеченный `{.trustedUnsafe.}` / `block trustedUnsafe:`.
- `atf_c_checker.nim` — **After-Codegen-Finish (ATF)** верификатор сгенерированного C-кода (`--check-safe-atf`), проверяющий `.c` файлы до вызова GCC на запрещённые небезопасные вызовы CRT (`malloc`/`free`/`strcpy` и др., `[ATF-001]`), сырую арифметику указателей (`[ATF-002]`), корректность ORC-хуков (`[ATF-003]`), возврат адресов стека (`[ATF-004]`) и наличие проверок границ/переполнения (`[ATF-005]`).

---

## Витринные приложения (Showcase MVP)

### 1. `apps/html_desktop` — Нативный HTML5/CSS3 Desktop Runner (Замена Tauri/Electron)
Рендерит автономные `.html` файлы (по умолчанию [`apps/html_desktop/ui/showcase.html`](apps/html_desktop/ui/showcase.html)) напрямую через **Vulkan 1.1+ SDF** без Chromium, WebView2 и Node.js. Логика и обработчики написаны на чистом Nim и связываются через `HtmlBindingRegistry`.

Поддерживает флаг `--file <путь.html>` для загрузки произвольных Zero-JS `.html` страниц, а также headless-экспорт PNG (`--headless-test --screenshot <out.png>`).

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

---

## Быстрый старт

### Требования
- **Nim `>= 2.0`** (проверено на `2.2.12`) + компилятор C (MinGW-W64 GCC / Clang) в `PATH`.
- **Windows 10/11 (x64)**: для интерактивных окон нужен драйвер **Vulkan 1.1+**; headless-тесты и генерация PNG работают на любом CPU через программный SDF-растеризатор.

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
# Базовые системные тесты CoreX / AlgX / MFT / Signals / IOCP
nimble test

# Полный набор тестов NimUI (Layout, Widgets, Zero-JS HTML5/CSS3) и QuickJS
nimble test_ui
nimble test_js

# Верификация гибридного memory-safe компилятора (--mem-safe, --safe-mode, --check-safe-atf)
nimble test_compiler

# Проверка всех 4 витринных приложений в headless-режиме + генерация скриншотов
nimble test_showcase

# Бенчмарки против Rust (генерирует benchmarks/showcase.html)
nimble showcase_html
```

---

## Поддерживаемые возможности HTML5 / CSS3 (`src/nimui/html_css.nim`)

| Категория | Поддержка в MVP v0.1.0 |
| :--- | :--- |
| **HTML-теги** | `html`, `body`, `div`, `section`, `header`, `footer`, `nav`, `main`, `aside`, `article`, `h1`–`h3`, `p`, `span`, `label`, `strong`, `em`, `a`, `button`, `input` (`type="text"` / `hidden`, `value`, `placeholder`), `head`, `style`, `meta`, `link`, `title` |
| **CSS-селекторы** | `*`, по тегу (`div`), `#id`, `.class`, комбинированные селекторы (`div.card`), потомки (`.row .btn`, `.row > .btn`), псевдоклассы `:hover`, `:active` |
| **Раскладка (Layout)** | `display`: `flex`, `block`, `inline`, `inline-block`, `none`; `flex-direction`: `row`, `column`; `justify-content`, `align-items` (`stretch`, `center`, `flex-end`); `width`/`height` (`px`, `%`), `flex-grow`, `flex`, `padding`, `padding-top/right/bottom/left`, `gap`, `overflow`/`overflow-y`, `text-align` |
| **Визуальный стиль (SDF)** | `color`, `background` / `background-color` (hex `#RGB`/`#RRGGBB`/`#RRGGBBAA` и именованные цвета), `border`, `border-width`, `border-color`, `border-radius`, `font-size` |
| **Реактивность без JS** | `data-click` (привязка к `HtmlClickProc`), `data-text` / `data-bind` (привязка к `Signal[string]` или `HtmlTextProc`), `data-model` / `data-input` (двусторонняя привязка `<input>`) |
| **Безопасность (Zero-JS)** | Строгий отказ (`Result.err`) при обнаружении `<script>`, любых `on*`-атрибутов (`onclick`, `onload` и т.д.) и `javascript:` URI |

---

## Дополнительная документация

Подробные проектные материалы перенесены в каталог [`docs/`](docs/):
- [`docs/PROJECT.md`](docs/PROJECT.md) — обзор архитектуры и подсистем.
- [`docs/MANIFEST.md`](docs/MANIFEST.md) — философский и технический манифест экосистемы.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — журнал архитектурных решений.
- [`docs/STATE.md`](docs/STATE.md) — состояние модулей и спринтов.
- [`docs/BENCHMARK_SHOWCASE.md`](docs/BENCHMARK_SHOWCASE.md) — методика и результаты сравнения `CoreX`/`AlgX` с Rust.
- [`docs/NIM_ROADMAP_FEATURES.md`](docs/NIM_ROADMAP_FEATURES.md) — дорожная карта развития.
