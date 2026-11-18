# Distribution, Updates, Signing & Privacy Policy (`docs/DISTRIBUTION.md`)

> **Item 13 Specification** — Distribution & Update Model, Code Signing / Unsigned Policy, Separate Runtime vs App Versioning, Privacy-First Crash Reporting, and Uninstall / Cleanup.

---

## 1. Distribution & Update Model

NimRT targets **Windows 10/11 x64** with a **hybrid distribution model** built around self-contained native executables (~8–15 MB, zero Chromium/WebView2/runtime installer dependencies):

| Channel | Format | Target Audience | Update Mechanism |
| :--- | :--- | :--- | :--- |
| **Portable (Default MVP v0.1.0)** | `nimrt-vX.Y.Z-win64-portable.zip` + standalone `.exe` binaries | Developers, power users, air-gapped / enterprise workstations | Manual replace or user-initiated update check against GitHub Releases + `SHA256SUMS.txt` |
| **Installer (Roadmap v0.2+)** | Per-user MSI / Inno Setup (`%LOCALAPPDATA%\Programs\NimRT\`) | End-user desktop applications built on NimRT | Signed installer upgrade in-place without requiring Administrator elevation |
| **Hybrid Mode** | Single `.exe` that detects `portable.flag` (or `.exe` directory writeability) | Utility apps (e.g. `wiztree`, `html_desktop`) | Stores config/cache next to `.exe` in portable mode, or under `%LOCALAPPDATA%\NimRT\<appId>\` when installed |

### Update Invariants
1. **No silent background updaters:** NimRT never installs background Windows Services or scheduled tasks without explicit user consent.
2. **Integrity verification before swap:** Any downloaded update archive or binary must match its published `SHA256SUMS.txt` digest before replacing the active binary.
3. **Atomic rollback:** During self-update, the previous binary is renamed to `<app>.exe.bak` until the new binary passes a startup health check.

---

## 2. Code Signing & Unsigned Binary Policy

### Current Policy (v0.1.0 MVP)
- Prebuilt GitHub Release binaries in v0.1.0 are **unsigned** open-source builds compiled directly on GitHub-hosted `windows-latest` runners.
- Every release publishes **`SHA256SUMS.txt`** alongside the binaries so users can verify integrity before running:
  ```powershell
  Get-FileHash .\html_desktop.exe -Algorithm SHA256
  Get-Content .\SHA256SUMS.txt
  ```
- **Windows SmartScreen Notice:** Because the v0.1.0 binaries are unsigned, Windows Defender SmartScreen may display *"Windows protected your PC"*. Users who have verified the `SHA256SUMS.txt` hash (or built from source via `nimble build_release`) can click **More info -> Run anyway**.

### Signed Release Roadmap (v0.2+)
- Production releases of end-user installers and binaries will use **Azure Trusted Signing** or **EV/OV Authenticode** in `.github/workflows/release.yml` (via `signtool.exe` with RFC 3161 timestamping), eliminating SmartScreen warnings while keeping `SHA256SUMS.txt` published for reproducible verification.

---

## 3. Separate Runtime vs App Versioning

NimRT strictly separates **runtime/SDK versioning** from **application versioning**:

| Layer | Version Identifier | Meaning & Compatibility Rule |
| :--- | :--- | :--- |
| **NimRT Runtime & Component SDK** | `SDK_API_VERSION` (e.g. `0.1.0` in [`src/nimui/sdk/contract.nim`](../src/nimui/sdk/contract.nim)) | Governs `corex`, `algx`, `nimui`, and `nimui/sdk` block contracts. Checked via SemVer (`isCompatibleWith`). |
| **Downstream Application** | `appVersion` (e.g. `1.4.2` in app manifest / release tag) | Governs the end-user product's features, data migrations, and UI release cadence. |

An application built with NimRT declares both its own `appVersion` and its `minSdkVersion`. Upgrading an app does not break third-party SDK blocks unless `SDK_API_VERSION` crosses a breaking boundary (minor bump in `0.x`, major bump in `>= 1.0`).

---

## 4. Privacy-First Crash Reporting

NimRT enforces a **zero-telemetry-by-default** policy:

1. **Disabled by default:** No crash reports, analytics, usage metrics, or network pings are ever sent automatically.
2. **Local-first diagnostics:** On an unhandled crash or Vulkan device-lost event, diagnostics are written locally to `%LOCALAPPDATA%\NimRT\<appId>\crashes\` (or `./crashes/` in portable mode).
3. **Explicit user consent & inspection:** If an app enables optional crash reporting, it must show the exact scrubbed payload (OS build, NimRT version, app version, anonymized stack trace) to the user and require an explicit click (**"Send Report"**) before making any network request.
4. **Automatic PII scrubbing:** File paths (e.g. `C:\Users\<username>\...`), environment variables, command-line arguments, and local storage contents are stripped before display or export.

---

## 5. Uninstall & Cleanup

### Portable Mode
1. Delete the application directory (or standalone `.exe`).
2. Optionally remove local state if created:
   ```powershell
   Remove-Item -Recurse -Force "$env:LOCALAPPDATA\NimRT\<appId>" -ErrorAction SilentlyContinue
   ```

### Installer Mode (v0.2+)
- Standard Windows **Add or Remove Programs** (`Apps & Features`) uninstaller removes:
  - Application binaries from `%LOCALAPPDATA%\Programs\NimRT\<appId>\`
  - Start Menu / Desktop shortcuts
  - Uninstall registry entry under `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\`
- **User data prompt:** The uninstaller preserves `%LOCALAPPDATA%\NimRT\<appId>\` by default and offers an explicit checkbox (*"Also delete local app data and caches"*) for complete cleanup.
- **Zero system-wide residue:** No kernel drivers, no global PATH mutations, and no background services are installed.
