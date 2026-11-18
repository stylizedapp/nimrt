## nimui/sdk/contract — Third-Party Component & System Block Contract / Versioning
##
## Strict invariants:
## - SemVer 2.0.0 compatibility checks (0.x requires matching major & minor; >=1.0 requires matching major).
## - Third-party blocks must declare id, version, minSdkVersion, kind, and requiredPermissions.
## - Registry enforces SDK compatibility and PermissionPolicy before block invocation.

import std/strutils
import corex/result
import ./permissions

type
  SemVer* = object
    major*: uint16
    minor*: uint16
    patch*: uint16

  BlockKind* = enum
    bkUi = "ui"
    bkSystem = "system"

  PropType* = enum
    ptString = "string"
    ptInt = "int"
    ptFloat = "float"
    ptBool = "bool"
    ptList = "list"
    ptObject = "object"
    ptCallback = "callback"

  PropSpec* = object
    name*: string
    propType*: PropType
    required*: bool
    defaultValue*: string

  BlockManifest* = object
    id*: string
    name*: string
    version*: SemVer
    minSdkVersion*: SemVer
    kind*: BlockKind
    requiredPermissions*: PermissionSet
    propsSchema*: seq[PropSpec]

  BlockRegistry* = object
    sdkVersion*: SemVer
    manifests*: seq[BlockManifest]

const
  SDK_API_VERSION* = SemVer(major: 0'u16, minor: 1'u16, patch: 0'u16)

proc `$`*(v: SemVer): string {.raises: [].} =
  $v.major & "." & $v.minor & "." & $v.patch

proc parseUint16Strict(s: string): SdkResult[uint16] {.raises: [].} =
  if s.len == 0 or s.len > 5:
    return SdkResult[uint16].err(makeSdkErr(sdkErrInvalidInput, "Invalid version component: " & s))
  var acc: uint32 = 0
  for ch in s:
    if ch < '0' or ch > '9':
      return SdkResult[uint16].err(makeSdkErr(sdkErrInvalidInput, "Non-digit in version component: " & s))
    acc = acc * 10'u32 + uint32(ord(ch) - ord('0'))
    if acc > 65535'u32:
      return SdkResult[uint16].err(makeSdkErr(sdkErrInvalidInput, "Version component overflow: " & s))
  SdkResult[uint16].ok(uint16(acc))

proc parseSemVer*(s: string): SdkResult[SemVer] {.raises: [].} =
  ## Parses "MAJOR.MINOR.PATCH" into SemVer without raising exceptions.
  let parts = s.strip().split('.')
  if parts.len != 3:
    return SdkResult[SemVer].err(makeSdkErr(sdkErrInvalidInput, "Expected MAJOR.MINOR.PATCH, got: " & s))
  let maj = parseUint16Strict(parts[0])
  if maj.isErr: return SdkResult[SemVer].err(maj.unwrapErr())
  let min = parseUint16Strict(parts[1])
  if min.isErr: return SdkResult[SemVer].err(min.unwrapErr())
  let pat = parseUint16Strict(parts[2])
  if pat.isErr: return SdkResult[SemVer].err(pat.unwrapErr())
  SdkResult[SemVer].ok(SemVer(major: maj.unwrap(), minor: min.unwrap(), patch: pat.unwrap()))

proc cmp*(a, b: SemVer): int {.raises: [].} =
  if a.major != b.major: return (if a.major < b.major: -1 else: 1)
  if a.minor != b.minor: return (if a.minor < b.minor: -1 else: 1)
  if a.patch != b.patch: return (if a.patch < b.patch: -1 else: 1)
  0

proc isCompatibleWith*(host, required: SemVer): bool {.raises: [].} =
  ## SemVer compatibility:
  ## - Pre-1.0 (major == 0): host.major == 0, host.minor == required.minor, host.patch >= required.patch
  ## - Stable (major >= 1): host.major == required.major, (host.minor, host.patch) >= (required.minor, required.patch)
  if host.major != required.major:
    return false
  if host.major == 0'u16:
    return host.minor == required.minor and host.patch >= required.patch
  cmp(host, required) >= 0

proc initBlockRegistry*(sdkVersion: SemVer = SDK_API_VERSION): BlockRegistry {.raises: [].} =
  BlockRegistry(sdkVersion: sdkVersion, manifests: @[])

proc findBlock*(reg: BlockRegistry, id: string): int {.raises: [].} =
  for i, m in reg.manifests:
    if m.id == id:
      return i
  -1

proc validateManifest*(reg: BlockRegistry, manifest: BlockManifest): SdkResult[void] {.raises: [].} =
  if manifest.id.strip().len == 0:
    return SdkResult[void].err(makeSdkErr(sdkErrInvalidInput, "Block manifest id must not be empty"))
  if manifest.name.strip().len == 0:
    return SdkResult[void].err(makeSdkErr(sdkErrInvalidInput, "Block manifest name must not be empty"))
  if not reg.sdkVersion.isCompatibleWith(manifest.minSdkVersion):
    return SdkResult[void].err(makeSdkErr(
      sdkErrIncompatibleVersion,
      "Block '" & manifest.id & "' requires SDK " & $manifest.minSdkVersion &
        ", incompatible with host SDK " & $reg.sdkVersion
    ))
  SdkResult[void].ok()

proc registerBlock*(reg: var BlockRegistry, manifest: BlockManifest): SdkResult[void] {.raises: [].} =
  let valid = reg.validateManifest(manifest)
  if valid.isErr:
    return valid
  if reg.findBlock(manifest.id) >= 0:
    return SdkResult[void].err(makeSdkErr(sdkErrAlreadyExists, "Block already registered: " & manifest.id))
  reg.manifests.add(manifest)
  SdkResult[void].ok()

proc checkBlockInvocation*(
  reg: BlockRegistry,
  id: string,
  policy: var PermissionPolicy
): SdkResult[BlockManifest] {.raises: [].} =
  ## Looks up block `id`, verifies SDK compatibility and checks all `requiredPermissions`.
  let idx = reg.findBlock(id)
  if idx < 0:
    return SdkResult[BlockManifest].err(makeSdkErr(sdkErrNotFound, "Block not registered: " & id))
  let manifest = reg.manifests[idx]
  if not reg.sdkVersion.isCompatibleWith(manifest.minSdkVersion):
    return SdkResult[BlockManifest].err(makeSdkErr(
      sdkErrIncompatibleVersion,
      "Block '" & id & "' incompatible with host SDK " & $reg.sdkVersion
    ))
  for perm in manifest.requiredPermissions:
    let chk = policy.requirePermission(perm, "invoke:" & id, id)
    if chk.isErr:
      return SdkResult[BlockManifest].err(chk.unwrapErr())
  SdkResult[BlockManifest].ok(manifest)
