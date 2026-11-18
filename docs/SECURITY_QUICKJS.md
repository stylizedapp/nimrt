# QuickJS Sandbox Threat Model & Security Architecture

## 1. Opt-In Isolation Policy

QuickJS execution is **disabled by default** (`allowJs = false` in `parseHtmlDoc` and `newHtmlDesktopApp`).
- Without explicit opt-in, `<script>` tags, inline event handlers, and `javascript:` URIs are rejected at parse time.
- When opted-in (`allowJs = true` / `initQuickJsEngine` / `initHtmlJsSession`), `QuickJsConfig.isolated` defaults to `true`, creating a dedicated `JSRuntime`, `JSContext`, and `corex/allocators.Allocator` per session with no shared global JS state.

## 2. Threat Model

**Protected assets**:
- Host process memory and Nim allocator integrity (`TrackingAllocator` 0-leak audit).
- Host filesystem, network, process execution, and persistent storage.
- Host UI tree (`UiTree`) and registered `Nim.*` callbacks.

**Assumed adversary**:
- Untrusted or buggy `<script>` code attempting:
  - Dynamic code generation (`eval`, `Function`, `AsyncFunction`, `GeneratorFunction`, `import()`).
  - Prototype pollution (`__proto__`, `Object.setPrototypeOf`, `Proxy`, `Reflect`).
  - Privilege escalation across capabilities (`dom`, `timers`, `storage`, `network`, `fs`, `process`, `nim`, `console`).
  - Resource exhaustion (infinite loops, heap OOM bombs, deep recursion stack overflow).

**Non-goals / Out-of-scope**:
- Timing side-channels or OS-level process sandboxing (QuickJS runs in-process when opted in).

## 3. Defense-in-Depth Controls

### A. Static Philosophy & Syntax Gate (`src/nimui/js/js_validator.nim`)
- `[JS-R01]`: Forbids `var` (requires `const`/`let`).
- `[JS-R02]`: Forbids loose equality `==`/`!=` (requires `===`/`!==`).
- `[JS-R03]`: Forbids `eval`, `Function`, `with`, `__proto__`, `setPrototypeOf`, `Proxy`, `Reflect`.
- `[JS-R04]`: Forbids `import` statements and dynamic `import(...)`.

### B. C Runtime Hardening (`src/nimui/js/qjs_bridge.c`)
Even if JS code uses bracket indirection (e.g., `globalThis['ev' + 'al']` or `[].filter['constructor']`):
- `globalThis.eval`, `globalThis.Function`, and `Function.prototype.constructor` are replaced with throwing C stubs.
- `Object.setPrototypeOf` is replaced with a throwing C stub.
- `Proxy` and `Reflect` are deleted from `globalThis`.
- `JS_SetModuleLoaderFunc` installs `qjs_blocked_module_loader`, blocking dynamic `import()`.
- `JS_Eval` is always invoked with `JS_EVAL_FLAG_STRICT`.

### C. Separated Capabilities
| Capability | Identifiers | Default |
| --- | --- | --- |
| `dom` | `document`, `ui` | Granted in default UI config |
| `timers` | `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval` | Granted in default UI config |
| `console` | `console` | Granted in default UI config |
| `nim` | `Nim` | Granted in default UI config |
| `storage` | `storage`, `localStorage`, `sessionStorage` | **Denied** (explicit opt-in only) |
| `network` | `network`, `fetch`, `XMLHttpRequest`, `WebSocket` | **Denied** (explicit opt-in only) |
| `fs` | `fs`, `readFile`, `writeFile` | **Denied** (explicit opt-in only) |
| `process` | `process`, `child_process`, `exec`, `spawn` | **Denied** (explicit opt-in only) |

Note: `parseScriptCaps("all")` grants only `{dom, timers, nim, console}` and **never** silently grants `storage`, `network`, `fs`, or `process`. In `HtmlJsSession`, host ops `OpStorage..OpProcess` fail closed unless a host backend is explicitly attached.

### D. Resource Limits & Audit Logging
- Default limits: `8 MiB` heap (`JS_SetMemoryLimit`), `512 KiB` stack (`JS_SetMaxStackSize`), `250,000` VM steps per call (`JS_SetInterruptHandler`).
- `QuickJsEngine.auditLog` (and `onAudit` hook) records `jaValidationDenied`, `jaCapabilityDenied`, `jaEvalSuccess`, `jaEvalError`, and `jaResourceExhausted`.
