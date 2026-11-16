# Ручной чек-лист аппаратных и интерактивных проверок (`v0.1.0`)

Этот документ дополняет автоматизированный CI и headless-тесты (`nimble test_all`, `tests/test_showcase_apps.nim`) сценариями, которые требуют живого GPU/драйвера Vulkan, оконной подсистемы Windows, реального ввода IME или прав Администратора NTFS.

> **Языковая заметка:** `docs/MANUAL_CHECKLIST.md`, `docs/STATE.md`, `docs/BENCHMARK_SHOWCASE.md`, `docs/NIM_ROADMAP_FEATURES.md` и `README.md` ведутся на русском языке; `docs/MANIFEST.md`, `docs/PROJECT.md` и `docs/DECISIONS.md` ведутся на английском языке.

---

## 1. Vulkan Device Lost (`VK_ERROR_DEVICE_LOST`)

- **Затрагиваемый код:** `src/nimui/gpu/vulkan_backend.nim` (`recoverFromDeviceLost`, `renderInstancesResult`).
- **Как воспроизвести:**
  1. Запустить интерактивное приложение (например, `nimble html_desktop` или `nimble gallery`).
  2. Опционально собрать с `-d:nimuiValidation` (если установлен `VK_LAYER_KHRONOS_validation`).
  3. Спровоцировать сброс видеодрайвера (TDR / перезапуск драйвера через `Win+Ctrl+Shift+B` или отключение/переключение GPU в Диспетчере устройств).
- **Ожидаемый результат:**
  - Приложение перехватывает `VK_ERROR_DEVICE_LOST` и пытается выполнить восстановление через `recoverFromDeviceLost`.
  - Если драйвер не позволяет пересоздать устройство, приложение завершает цикл рендера корректно без падения (segfault/abort) и без бесконечного зависания.

---

## 2. Сворачивание окна (`0×0` swapchain / `IsIconic`)

- **Затрагиваемый код:** `src/nimui/window.nim`, `src/nimui/gpu/vulkan_backend.nim`.
- **Как воспроизвести:**
  1. Запустить `nimble gallery` или `nimble studio` (желательно с `-d:nimuiValidation`).
  2. Свернуть окно кнопкой Minimize (`_`) или `Win+Down`, подождать 2–3 секунды.
  3. Развернуть окно обратно (и попробовать изменить размер окна перетаскиванием границы).
- **Ожидаемый результат:**
  - При свёрнутом окне (`0×0` клиентская область / `IsIconic`) рендер пропускается, ошибки валидации Vulkan (`VUID-VkSwapchainCreateInfoKHR-imageExtent-...`) не возникают.
  - После разворачивания swapchain пересоздаётся и UI продолжает отрисовываться без артефактов.

---

## 3. Масштабирование DPI 125% / 150% (`WM_DPICHANGED`)

- **Затрагиваемый код:** `src/nimui/window.nim`, `src/nimui/gpu/font_atlas.nim` (`rebuildForDpi`).
- **Как воспроизвести:**
  1. В параметрах экрана Windows установить масштаб **125%** или **150%** (или перетащить окно между мониторами с разным DPI, например 100% ↔ 150%).
  2. Запустить `nimble gallery` и `nimble html_desktop`.
- **Ожидаемый результат:**
  - Окно получает `WM_DPICHANGED` и вызывает `rebuildForDpi` с новым `dpiScale`.
  - Текст и элементы layout масштабируются пропорционально, без обрезки и смещения hit-testing зон при кликах мышью.
  - Примечание: крупные цифры `64+pt` могут выглядеть мягче рамок SDF, так как текст использует GDI coverage-битмапы на `baseSize * dpiScale` (не SDF).

---

## 4. Ввод через IME-композицию (`WM_IME_COMPOSITION`)

- **Затрагиваемый код:** `src/nimui/window.nim` (`WM_IME_COMPOSITION`, конвертация UTF-16 → UTF-8).
- **Как воспроизвести:**
  1. Включить в Windows CJK-раскладку с IME (например, Microsoft Japanese IME или Chinese Pinyin IME).
  2. Запустить `nimble gallery`, сфокусировать `TextInput` или многострочный `TextArea`.
  3. Набрать последовательность символов с композицией и подтвердить ввод (`Enter`).
- **Ожидаемый результат:**
  - Итоговая скомпонованная строка корректно вставляется в поле ввода в UTF-8 без кракозябр и падений.
  - Известное ограничение v0.1.0: позиционирование inline-окна кандидатов IME не поддерживается (поддерживается только вставка результата композиции).

---

## 5. Права Администратора для прямого чтения NTFS `$MFT`

- **Затрагиваемый код:** `src/corex/mft.nim`, `src/corex/platform/windows/win32_mft.nim`, `apps/wiztree/scanner.nim`, `apps/everything/`.
- **Как воспроизвести:**
  1. **Обычный пользователь (без прав Администратора):**
     ```powershell
     nimble wiztree -- C:\
     ```
     Убедиться, что при отсутствии прав доступа к `\\.\C:` сканер прозрачно переключается на `scanWin32Fast` (`FindFirstFileExW`) и завершает работу без краша.
  2. **Повышенная консоль (Запуск от имени Администратора):**
     ```powershell
     nim c -d:release -r apps/wiztree/wiztree.nim C:\
     ```
     Убедиться, что используется прямой путь `FSCTL_ENUM_USN_DATA` / чтение `$MFT` тома `\\.\C:`, дерево строится корректно и результаты `Top-N` / `Extension Stats` совпадают с ожидаемыми.
