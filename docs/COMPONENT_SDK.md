# NimUI Component SDK (`nimui/sdk`)

> **Item 11 Specification** — Minimal UI Blocks, Capability-Gated System Blocks, Explicit Permissions, and Third-Party Block Contract.  
> Implementation: [`src/nimui/sdk.nim`](../src/nimui/sdk.nim) ([`permissions.nim`](../src/nimui/sdk/permissions.nim), [`contract.nim`](../src/nimui/sdk/contract.nim), [`ui_blocks.nim`](../src/nimui/sdk/ui_blocks.nim), [`system_blocks.nim`](../src/nimui/sdk/system_blocks.nim))  
> Verification: [`tests/test_component_sdk.nim`](../tests/test_component_sdk.nim)

---

## 1. Design Philosophy

The Component SDK follows NimRT's core invariants:
- **Zero-exception surface:** All fallible SDK operations return `SdkResult[T]` (`Result[T, SdkError]`) with `{.raises: [].}`.
- **Default-deny capabilities:** `defaultPermissionPolicy()` grants **zero** permissions (`granted = {}`, `readOnlyFs = true`). Every privileged action must be explicitly permitted and is recorded in `policy.auditLog`.
- **Retained-mode `UiTree` integration:** UI blocks build directly into `nimui/layout.UiTree` slabs with zero-allocation Flexbox layout and deterministic headless testing.

---

## 2. Explicit Permissions Model

Defined in [`src/nimui/sdk/permissions.nim`](../src/nimui/sdk/permissions.nim):

| Permission | Enum | String | Governs |
| :--- | :--- | :--- | :--- |
| Filesystem | `permFs` | `"fs"` | `FilePicker`, file-backed `SQLite`, `CSV` file I/O, `LocalStorage` disk persistence (`readOnlyFs` separates read vs write) |
| Network | `permNetwork` | `"network"` | `HTTP` requests (enforces `allowedHosts` when non-empty) |
| Process | `permProcess` | `"process"` | `Shell` command execution (enforces `allowedCommands` when non-empty, arg-array only) |
| Clipboard | `permClipboard` | `"clipboard"` | Clipboard read/write access |
| Notifications | `permNotifications` | `"notifications"` | OS-level `Toast` notifications (`osNotification = true`) |

---

## 3. Minimal UI Blocks (11)

Defined in [`src/nimui/sdk/ui_blocks.nim`](../src/nimui/sdk/ui_blocks.nim):

| # | Block | Constructor / API | Underlying Primitive | Permission |
| :--- | :--- | :--- | :--- | :--- |
| 1 | **Text** | `sdkText` | `dsl.Text` (`nkText`) | None |
| 2 | **Button** | `sdkButton` | `dsl.Button` (`nkButton`) | None |
| 3 | **Input** | `sdkInput` | `dsl.TextInput` (`nkTextInput`) | None |
| 4 | **List** | `sdkList` | `dsl.VirtualList` (`nkVirtualList`) | None |
| 5 | **Table** | `sdkTable` | `VStack` + `HStack` header/rows | None |
| 6 | **Image** | `sdkImage` | `dsl.Box` with `src`, `alt`, `ImageFit` | None |
| 7 | **Tabs** | `sdkTabs`, `switchTab` | `HStack` tab bar + `VStack` panels | None |
| 8 | **Modal** | `sdkModal`, `setModalOpen` | Backdrop + dialog `VStack` | None |
| 9 | **Toast** | `sdkToast`, `showToast`, `tickToast` | Transient banner (`tlInfo`/`tlSuccess`/`tlWarn`/`tlError`) | `permNotifications` (if `osNotification = true`) |
| 10 | **FilePicker** | `sdkFilePicker`, `pickFile` | `HStack` + `Button` + path `Text` | `permFs` (write check for `fpSaveFile`) |
| 11 | **Timer** | `sdkTimer`, `start`, `stop`, `reset`, `tick` | Deterministic step-driven timer | None |

---

## 4. System Blocks (6)

Defined in [`src/nimui/sdk/system_blocks.nim`](../src/nimui/sdk/system_blocks.nim):

| # | Block | Primary API | Permissions & Limits |
| :--- | :--- | :--- | :--- |
| 1 | **HTTP** | `execHttp`, `extractUrlHost` | `permNetwork` + `allowedHosts`; pluggable `HttpTransportProc` |
| 2 | **JSON** | `jsonParse`, `jsonStringify` | None; bounded to `MAX_JSON_INPUT_BYTES = 4 MiB`, `MAX_JSON_DEPTH = 64` |
| 3 | **SQLite** | `openSqlite`, `execSqlite`, `querySqlite`, `closeSqlite` | `:memory:` allowed without `permFs`; file paths require `permFs` |
| 4 | **CSV** | `parseCsv`, `formatCsv`, `readCsvFile`, `writeCsvFile` | In-memory RFC 4180 requires none; file I/O requires `permFs` |
| 5 | **LocalStorage** | `initLocalStorage`, `setItem`, `getItem`, `removeItem`, `saveLocalStorage` | Bounded byte quota (`maxBytes`); disk persistence requires `permFs` |
| 6 | **Shell** | `execShell` | `permProcess` + `allowedCommands`; strict `command` + `args` array (no shell string interpolation) |

---

## 5. Third-Party Block Contract & Versioning

Defined in [`src/nimui/sdk/contract.nim`](../src/nimui/sdk/contract.nim):

- **Host SDK API Version:** `SDK_API_VERSION = 0.1.0` (`SemVer`).
- **Manifest (`BlockManifest`):** Every third-party block declares:
  - `id`: unique reverse-DNS identifier (e.g. `"com.example.chart"`)
  - `name`: human-readable block name
  - `version`: block `SemVer`
  - `minSdkVersion`: minimum compatible host SDK `SemVer`
  - `kind`: `bkUi` or `bkSystem`
  - `requiredPermissions`: `PermissionSet`
  - `propsSchema`: typed `seq[PropSpec]` (`ptString`, `ptInt`, `ptFloat`, `ptBool`, `ptList`, `ptObject`, `ptCallback`)
- **SemVer Compatibility (`isCompatibleWith`):**
  - **Pre-1.0 (`0.y.z`):** `host.major == 0`, `host.minor == required.minor`, and `host.patch >= required.patch`.
  - **Stable (`>= 1.0.0`):** `host.major == required.major` and `host >= required`.
- **Invocation Gate (`checkBlockInvocation`):** Before invoking a registered block, `BlockRegistry` verifies SDK compatibility and enforces every permission in `manifest.requiredPermissions` against the active `PermissionPolicy`.
