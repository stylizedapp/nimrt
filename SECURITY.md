# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x (MVP) | :white_check_mark: |
| < 0.1.0 | :x:                |

## Security Architecture & Threat Model

NimRT is engineered with defense-in-depth principles:

1. **Zero-JS by Default (`allowJs = false`)**:
   - The HTML5/CSS3 renderer completely rejects `<script>`, inline event handlers (`onclick`, `onload`), and `javascript:` URIs unless explicitly opted-in with `allowJs = true`.
   - All logic and bindings are executed natively in compiled Nim through `HtmlBindingRegistry`.

2. **QuickJS Sandboxing (`allowJs = true`)**:
   - Strictly isolated embedded QuickJS instance with custom memory allocators routing through `corex/allocators.Allocator`.
   - Strict runtime limits: 8 MB heap memory quota, 512 KB call-stack limit, 250,000 opcode execution steps per tick.
   - AST/Syntax Philosophy rules: Prohibits `eval()`, `Function()`, `with`, `__proto__`, `var`, and loose equality `==`/`!=`.
   - Explicit capability declaration via `<script data-caps="...">` (e.g. `dom`, `timers`, `nim`, `console`). Scripts cannot access APIs they were not explicitly granted.

3. **Memory Safety & `nim_safe`**:
   - Deterministic memory management under `--mm:orc --threads:on --panics:on`.
   - The experimental `nim_safe` compiler enforces borrow-checking, prevents raw pointer arithmetic (`ptr`/`cast`), and validates emitted C code before GCC invocation (After-Codegen-Finish ATF checker).

4. **Filesystem Direct Access ($MFT)**:
   - Direct raw `$MFT` volume scanning (`apps/wiztree`, `corex/mft.nim`) requires Windows Administrator privileges.
   - When run without elevated privileges, the engine automatically falls back to standard Win32 directory APIs (`FindFirstFileExW`).

## Reporting a Vulnerability

If you discover a security vulnerability or sandbox bypass in NimRT:

1. **Do not create a public GitHub issue.**
2. Send a report directly via GitHub Security Advisories ([Report a vulnerability](https://github.com/stylizedapp/nimrt/security/advisories/new)) or contact the maintainers.
3. Please include:
   - A clear description of the vulnerability.
   - Minimal reproduction code or test HTML/JS payload.
   - Potential impact and affected subsystems.

We acknowledge receipt of security reports within 48 hours and work with reporters on responsible disclosure and patched releases.
