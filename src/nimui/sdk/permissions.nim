## nimui/sdk/permissions — Explicit Capability & Permission Model for Component SDK
##
## Strict invariants:
## - Default-deny: no elevated permissions are granted unless explicitly listed.
## - All permission checks return Result[void, SdkError] without raising exceptions.
## - Every check is recorded in an in-memory audit log for observability.

import std/strutils
import corex/result

type
  SdkPermission* = enum
    permFs = "fs"
    permNetwork = "network"
    permProcess = "process"
    permClipboard = "clipboard"
    permNotifications = "notifications"

  PermissionSet* = set[SdkPermission]

  SdkErrorKind* = enum
    sdkErrPermissionDenied
    sdkErrInvalidInput
    sdkErrIncompatibleVersion
    sdkErrNotFound
    sdkErrAlreadyExists
    sdkErrQuotaExceeded
    sdkErrIoFailure
    sdkErrProcessFailure
    sdkErrNetworkFailure

  SdkError* = object
    kind*: SdkErrorKind
    message*: string
    permission*: string

  SdkResult*[T] = Result[T, SdkError]

  PermissionAuditEntry* = object
    permission*: SdkPermission
    action*: string
    target*: string
    allowed*: bool

  PermissionPolicy* = object
    granted*: PermissionSet
    readOnlyFs*: bool
    allowedHosts*: seq[string]
    allowedCommands*: seq[string]
    auditLog*: seq[PermissionAuditEntry]

proc makeSdkErr*(kind: SdkErrorKind, message: string, perm: string = ""): SdkError {.inline, raises: [].} =
  SdkError(kind: kind, message: message, permission: perm)

proc defaultPermissionPolicy*(): PermissionPolicy {.raises: [].} =
  ## Returns a strict default-deny policy with zero granted permissions.
  PermissionPolicy(
    granted: {},
    readOnlyFs: true,
    allowedHosts: @[],
    allowedCommands: @[],
    auditLog: @[]
  )

proc parsePermission*(name: string): SdkResult[SdkPermission] {.raises: [].} =
  ## Parses a single capability string (case-insensitive) into SdkPermission.
  let norm = name.strip().toLowerAscii()
  case norm
  of "fs": SdkResult[SdkPermission].ok(permFs)
  of "network": SdkResult[SdkPermission].ok(permNetwork)
  of "process": SdkResult[SdkPermission].ok(permProcess)
  of "clipboard": SdkResult[SdkPermission].ok(permClipboard)
  of "notifications": SdkResult[SdkPermission].ok(permNotifications)
  else:
    SdkResult[SdkPermission].err(makeSdkErr(sdkErrInvalidInput, "Unknown permission: " & name))

proc parsePermissions*(caps: string): SdkResult[PermissionSet] {.raises: [].} =
  ## Parses a comma-separated capability list (e.g. "fs,network").
  var res: PermissionSet = {}
  if caps.strip().len == 0:
    return SdkResult[PermissionSet].ok(res)
  for part in caps.split(','):
    let trimmed = part.strip()
    if trimmed.len == 0:
      continue
    let parsed = parsePermission(trimmed)
    if parsed.isErr:
      return SdkResult[PermissionSet].err(parsed.unwrapErr())
    res.incl(parsed.unwrap())
  SdkResult[PermissionSet].ok(res)

proc recordAudit(policy: var PermissionPolicy, perm: SdkPermission, action, target: string, allowed: bool) {.raises: [].} =
  policy.auditLog.add(PermissionAuditEntry(
    permission: perm,
    action: action,
    target: target,
    allowed: allowed
  ))

proc requirePermission*(
  policy: var PermissionPolicy,
  perm: SdkPermission,
  action: string,
  target: string = ""
): SdkResult[void] {.raises: [].} =
  ## Verifies that `perm` is granted in `policy` and records an audit entry.
  if perm notin policy.granted:
    policy.recordAudit(perm, action, target, false)
    return SdkResult[void].err(makeSdkErr(
      sdkErrPermissionDenied,
      "Permission '" & $perm & "' denied for action '" & action & "'",
      $perm
    ))
  policy.recordAudit(perm, action, target, true)
  SdkResult[void].ok()

proc requireFsWrite*(policy: var PermissionPolicy, action, path: string): SdkResult[void] {.raises: [].} =
  ## Verifies `permFs` and ensures `readOnlyFs` is false for write operations.
  let base = policy.requirePermission(permFs, action, path)
  if base.isErr:
    return base
  if policy.readOnlyFs:
    policy.recordAudit(permFs, action & ":write", path, false)
    return SdkResult[void].err(makeSdkErr(
      sdkErrPermissionDenied,
      "Filesystem policy is read-only for action '" & action & "'",
      $permFs
    ))
  SdkResult[void].ok()

proc requireNetworkHost*(policy: var PermissionPolicy, action, host: string): SdkResult[void] {.raises: [].} =
  ## Verifies `permNetwork` and checks `allowedHosts` if non-empty.
  let base = policy.requirePermission(permNetwork, action, host)
  if base.isErr:
    return base
  if policy.allowedHosts.len > 0:
    let normHost = host.strip().toLowerAscii()
    var matched = false
    for allowed in policy.allowedHosts:
      if allowed.strip().toLowerAscii() == normHost:
        matched = true
        break
    if not matched:
      policy.recordAudit(permNetwork, action & ":host", host, false)
      return SdkResult[void].err(makeSdkErr(
        sdkErrPermissionDenied,
        "Network host '" & host & "' is not in allowedHosts",
        $permNetwork
      ))
  SdkResult[void].ok()

proc requireProcessCommand*(policy: var PermissionPolicy, action, command: string): SdkResult[void] {.raises: [].} =
  ## Verifies `permProcess` and checks `allowedCommands` if non-empty.
  let base = policy.requirePermission(permProcess, action, command)
  if base.isErr:
    return base
  if policy.allowedCommands.len > 0:
    let normCmd = command.strip().toLowerAscii()
    var matched = false
    for allowed in policy.allowedCommands:
      if allowed.strip().toLowerAscii() == normCmd:
        matched = true
        break
    if not matched:
      policy.recordAudit(permProcess, action & ":cmd", command, false)
      return SdkResult[void].err(makeSdkErr(
        sdkErrPermissionDenied,
        "Process command '" & command & "' is not in allowedCommands",
        $permProcess
      ))
  SdkResult[void].ok()
