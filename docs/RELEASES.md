# Releases, Artifacts & Deployment Guide (`docs/RELEASES.md`)

> **Item 17 Specification** — How NimRT publishes GitHub Releases, Actions build artifacts, and what end-users & developers should install.

---

## 1. What Users Install

NimRT ships **self-contained Windows x64 binaries** with zero external browser runtimes (no Chromium, no WebView2, no Node.js).

| Artifact | Purpose | Who Should Download |
| :--- | :--- | :--- |
| **`nimrt-vX.Y.Z-win64-portable.zip`** | Complete portable bundle (`*.exe` + `README.md` + `LICENSE` + `DISTRIBUTION.md` + `FOCUS.md`) | **Most users** evaluating NimRT or running the standalone tools |
| **`html_desktop.exe`** | Standalone HTML5/CSS3 desktop renderer (`Zero-JS` default + opt-in QuickJS) | Users running local `.html` desktop apps without a browser |
| **`wiztree.exe`** | NTFS `$MFT` / Win32 fast disk usage analyzer CLI | Users/admins inspecting disk usage |
| **`widget_gallery.exe`** | Interactive Vulkan 1.1+ SDF widget & typography showcase | UI developers testing NimUI rendering on their GPU |
| **`nim_safe.exe`** | Experimental memory-safe Nim compiler wrapper (`--mem-safe`, `--check-safe-atf`) | Nim developers testing static/ATF safety checks |
| **`SHA256SUMS.txt`** | SHA-256 digests for every `.exe` and `.zip` | **Everyone** — verify before running unsigned binaries |

---

## 2. GitHub Releases & Actions Artifacts

- **GitHub Releases (`v*.*.*` tags):** Triggered automatically by pushing a `v*.*.*` tag via [`.github/workflows/release.yml`](../.github/workflows/release.yml). Runs pre-release SDK & UI checks, builds release binaries (`nimble build_release`), packages the portable `.zip`, generates `SHA256SUMS.txt`, and publishes release notes.
- **GitHub Actions Artifacts (`workflow_dispatch` or tag):** Every run of `release.yml` uploads `nimrt-<tag>-win64` as a 30-day Actions artifact for verification before or alongside a release.
- **GitHub Packages / Deployments:** NimRT does not publish npm, NuGet, or Docker container packages (consistent with its native single-binary, zero-Node.js philosophy in [`docs/FOCUS.md`](FOCUS.md)). Distribution happens exclusively via GitHub Releases, Actions artifacts, and source builds (`nimble build_release`).

---

## 3. Verifying & Running a Release

```powershell
# 1. Verify SHA-256 checksum against SHA256SUMS.txt
Get-FileHash .\nimrt-v04.03.03-win64-portable.zip -Algorithm SHA256
Get-Content .\SHA256SUMS.txt

# 2. Extract portable archive and run
Expand-Archive .\nimrt-v04.03.03-win64-portable.zip -DestinationPath .\nimrt
.\nimrt\widget_gallery.exe
```

For code signing status, SmartScreen guidance, runtime vs app versioning, and uninstall instructions, see [`docs/DISTRIBUTION.md`](DISTRIBUTION.md).
