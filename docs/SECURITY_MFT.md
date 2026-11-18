# NTFS MFT Parser Security & Privilege Boundaries

## 1. When MFT Parsing Is Used

Direct NTFS Master File Table (MFT) parsing (`src/corex/mft.nim`, `src/corex/platform/windows/win32_mft.nim`) is used **only** when:
1. A tool (e.g., `apps/wiztree`) is explicitly invoked in direct MFT mode (`--mode:mft`) on an **NTFS volume root** on Windows.
2. The caller provides **explicit user consent** (`explicitConsent = true` in `openMftStreamer`).
3. The process **already** holds the required Windows privileges (Administrator / `SeManageVolumePrivilege` / `SeBackupPrivilege`).

In all other cases (non-root paths, non-NTFS volumes, unprivileged processes, or non-Windows platforms), callers fall back transparently to standard directory traversal (`walkDirFast` / `FindFirstFileW`).

## 2. Read-Only, Explicit Consent & No Silent Escalation

- **Strictly Read-Only**: `openMftStreamer` opens `\\.\<drive>:` exclusively with `GENERIC_READ` and `FILE_SHARE_READ or FILE_SHARE_WRITE`. No write, trim, or metadata-mutation IOCTLs are ever issued.
- **Explicit Consent**: `openMftStreamer(drive, bufferSize, explicitConsent = false)` rejects raw volume access unless `explicitConsent == true`.
- **Drive Validation**: Only single ASCII drive letters (`A..Z`, `a..z`) are accepted; arbitrary device paths are rejected.
- **No Silent Admin Escalation**: The engine **never** invokes `ShellExecute("runas")`, COM elevation monikers, or UAC prompts. If `CreateFileW` returns `ERROR_ACCESS_DENIED (5)`, `openMftStreamer` returns `Result.err` cleanly.

## 3. Strict Parsing Mode (`mpmStrict`)

`parseMftRecord` supports `parseMode: MftParseMode = mpmLenient | mpmStrict`, and `parseMftBufferStrict` processes multi-record buffers returning both partial valid `MftEntry` results and per-record errors without crashing:
- Validates `'FILE'` magic (`0x454C4946`) and rejects `'BAAD'` (`0x44414142`).
- Validates multi-sector Update Sequence Array (USA) fixups.
- In `mpmStrict`:
  - Enforces `firstAttrOffset >= 42` and `<= MFT_RECORD_SIZE - 8`, and `bytesUsed` within `[firstAttrOffset, MFT_RECORD_SIZE]`.
  - Enforces 8-byte aligned attribute lengths (`(attrLen and 7) == 0`) and bounds within the 1024-byte record.
  - Rejects negative `$FILE_NAME` / `$DATA` sizes and truncated or malformed runlists via `parseRunList`.
  - Ignores trailing partial bytes (< 1024) while reporting an error.

## 4. Windows Version Dependencies

- **Windows 2000+**: NTFS v3.0/v3.1 on-disk MFT record format (1024-byte records, 512-byte USA fixup sectors).
- **Windows XP / Server 2003+**: `FSCTL_GET_NTFS_VOLUME_DATA`, `SetFilePointerEx`, `FILE_FLAG_NO_BUFFERING` + `VirtualAlloc` sector-aligned reads.
- **Windows Vista+ (UAC)**: Raw volume handles (`\\.\C:`) require an elevated Administrator token even when the user account is in the Administrators group.
- **Non-Windows (Linux/macOS)**: `openMftStreamer` and `streamAll` compile as safe stubs returning `Result.err`.
