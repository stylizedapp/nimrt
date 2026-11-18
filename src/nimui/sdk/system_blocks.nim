## nimui/sdk/system_blocks — Capability-Gated System Blocks for Component SDK
##
## Provides the 6 system building blocks with explicit PermissionPolicy enforcement:
##   1. HTTP          (requires `permNetwork` + host allowlist)
##   2. JSON          (pure data, bounded depth/size; no elevated permission)
##   3. SQLite        (in-memory allowed; file-backed requires `permFs`)
##   4. CSV           (in-memory parse/format; file I/O requires `permFs`)
##   5. LocalStorage  (scoped KV store with byte quota; persistence requires `permFs`)
##   6. Shell         (requires `permProcess` + command allowlist, arg-array only)
##
## Strict invariants:
## - Zero-exception {.raises: [].} APIs returning SdkResult[T].
## - Default-deny: every privileged operation fails with sdkErrPermissionDenied unless granted.

import std/[strutils, json, tables, os, osproc, streams]
import corex/result
import ./permissions

# =============================================================================
# 1. HTTP Block (permNetwork)
# =============================================================================

type
  HttpMethod* = enum
    hmGet = "GET"
    hmPost = "POST"
    hmPut = "PUT"
    hmDelete = "DELETE"
    hmHead = "HEAD"

  HttpRequest* = object
    httpMethod*: HttpMethod
    url*: string
    headers*: seq[(string, string)]
    body*: string
    timeoutMs*: int

  HttpResponse* = object
    status*: int
    headers*: seq[(string, string)]
    body*: string

  HttpTransportProc* = proc(req: HttpRequest): SdkResult[HttpResponse] {.closure, gcsafe, raises: [].}

proc extractUrlHost*(url: string): SdkResult[string] {.raises: [].} =
  let trimmed = url.strip()
  let schemeIdx = trimmed.find("://")
  if schemeIdx <= 0:
    return SdkResult[string].err(makeSdkErr(sdkErrInvalidInput, "URL must include scheme (http:// or https://): " & url))
  let scheme = trimmed[0 ..< schemeIdx].toLowerAscii()
  if scheme != "http" and scheme != "https":
    return SdkResult[string].err(makeSdkErr(sdkErrInvalidInput, "Unsupported URL scheme: " & scheme))
  let rest = trimmed[schemeIdx + 3 .. ^1]
  if rest.len == 0:
    return SdkResult[string].err(makeSdkErr(sdkErrInvalidInput, "URL missing host: " & url))
  var endIdx = rest.find('/')
  if endIdx < 0:
    endIdx = rest.len
  let hostPort = rest[0 ..< endIdx]
  let colonIdx = hostPort.find(':')
  let host = if colonIdx >= 0: hostPort[0 ..< colonIdx] else: hostPort
  if host.len == 0:
    return SdkResult[string].err(makeSdkErr(sdkErrInvalidInput, "Empty host in URL: " & url))
  SdkResult[string].ok(host.toLowerAscii())

proc execHttp*(
  policy: var PermissionPolicy,
  req: HttpRequest,
  transport: HttpTransportProc = nil
): SdkResult[HttpResponse] {.raises: [].} =
  ## Enforces `permNetwork` + `allowedHosts`, then delegates to `transport`.
  let hostRes = extractUrlHost(req.url)
  if hostRes.isErr:
    return SdkResult[HttpResponse].err(hostRes.unwrapErr())
  let host = hostRes.unwrap()
  let perm = policy.requireNetworkHost("http:" & $req.httpMethod, host)
  if perm.isErr:
    return SdkResult[HttpResponse].err(perm.unwrapErr())
  if transport == nil:
    return SdkResult[HttpResponse].err(makeSdkErr(sdkErrNetworkFailure, "No HTTP transport configured for host: " & host, $permNetwork))
  transport(req)

# =============================================================================
# 2. JSON Block (pure, bounded)
# =============================================================================

const
  MAX_JSON_INPUT_BYTES* = 4 * 1024 * 1024
  MAX_JSON_DEPTH* = 64

proc checkJsonDepth(node: JsonNode, depth: int): bool {.raises: [].} =
  if depth > MAX_JSON_DEPTH:
    return false
  case node.kind
  of JObject:
    for _, v in node.pairs:
      if not checkJsonDepth(v, depth + 1):
        return false
  of JArray:
    for elem in node.elems:
      if not checkJsonDepth(elem, depth + 1):
        return false
  else:
    discard
  true

proc jsonParse*(raw: string): SdkResult[JsonNode] {.raises: [].} =
  if raw.len > MAX_JSON_INPUT_BYTES:
    return SdkResult[JsonNode].err(makeSdkErr(sdkErrQuotaExceeded, "JSON input exceeds 4MB limit"))
  try:
    let node = parseJson(raw)
    if not checkJsonDepth(node, 0):
      return SdkResult[JsonNode].err(makeSdkErr(sdkErrInvalidInput, "JSON nesting exceeds max depth " & $MAX_JSON_DEPTH))
    SdkResult[JsonNode].ok(node)
  except CatchableError as e:
    SdkResult[JsonNode].err(makeSdkErr(sdkErrInvalidInput, "JSON parse error: " & e.msg))

proc jsonStringify*(node: JsonNode, pretty: bool = false): SdkResult[string] {.raises: [].} =
  if node == nil:
    return SdkResult[string].err(makeSdkErr(sdkErrInvalidInput, "Cannot stringify nil JsonNode"))
  if not checkJsonDepth(node, 0):
    return SdkResult[string].err(makeSdkErr(sdkErrInvalidInput, "JSON nesting exceeds max depth " & $MAX_JSON_DEPTH))
  try:
    if pretty:
      SdkResult[string].ok(pretty(node))
    else:
      SdkResult[string].ok($node)
  except CatchableError as e:
    SdkResult[string].err(makeSdkErr(sdkErrInvalidInput, "JSON stringify error: " & e.msg))

# =============================================================================
# 3. SQLite Block (in-memory or permFs for file-backed DB)
# =============================================================================

type
  SqliteConfig* = object
    path*: string          ## ":memory:" or file path
    readOnly*: bool

  SqliteRow* = seq[string]

  SqliteQueryResult* = object
    columns*: seq[string]
    rows*: seq[SqliteRow]

  SqliteDb* = object
    config*: SqliteConfig
    isOpen*: bool
    tables*: Table[string, SqliteQueryResult]

proc openSqlite*(policy: var PermissionPolicy, config: SqliteConfig): SdkResult[SqliteDb] {.raises: [].} =
  let normPath = config.path.strip()
  if normPath.len == 0:
    return SdkResult[SqliteDb].err(makeSdkErr(sdkErrInvalidInput, "SQLite path cannot be empty"))
  if normPath != ":memory:":
    let permRes =
      if config.readOnly:
        policy.requirePermission(permFs, "sqlite:open_ro", normPath)
      else:
        policy.requireFsWrite("sqlite:open_rw", normPath)
    if permRes.isErr:
      return SdkResult[SqliteDb].err(permRes.unwrapErr())
  SdkResult[SqliteDb].ok(SqliteDb(
    config: config,
    isOpen: true,
    tables: initTable[string, SqliteQueryResult]()
  ))

proc closeSqlite*(db: var SqliteDb) {.raises: [].} =
  db.isOpen = false
  db.tables.clear()

proc execSqlite*(db: var SqliteDb, sql: string): SdkResult[int] {.raises: [].} =
  ## Executes minimal DDL/DML on the in-memory table store (CREATE TABLE, INSERT INTO)
  ## or validates statement readiness. Returns affected row count.
  if not db.isOpen:
    return SdkResult[int].err(makeSdkErr(sdkErrInvalidInput, "SQLite database is closed"))
  let trimmed = sql.strip()
  if trimmed.len == 0:
    return SdkResult[int].err(makeSdkErr(sdkErrInvalidInput, "SQL statement cannot be empty"))
  let lower = trimmed.toLowerAscii()
  if lower.startsWith("create table "):
    let rest = trimmed[13 .. ^1].strip()
    let paren = rest.find('(')
    let name = (if paren > 0: rest[0 ..< paren] else: rest).strip()
    if name.len == 0:
      return SdkResult[int].err(makeSdkErr(sdkErrInvalidInput, "Missing table name in CREATE TABLE"))
    var cols: seq[string] = @[]
    if paren >= 0:
      let closeParen = rest.rfind(')')
      if closeParen > paren:
        for colDef in rest[paren + 1 ..< closeParen].split(','):
          let colParts = colDef.strip().splitWhitespace()
          if colParts.len > 0:
            cols.add(colParts[0])
    db.tables[name] = SqliteQueryResult(columns: cols, rows: @[])
    return SdkResult[int].ok(0)
  elif lower.startsWith("insert into "):
    let rest = trimmed[12 .. ^1].strip()
    let valsIdx = rest.toLowerAscii().find("values")
    if valsIdx <= 0:
      return SdkResult[int].err(makeSdkErr(sdkErrInvalidInput, "INSERT requires VALUES clause"))
    let tablePart = rest[0 ..< valsIdx].strip()
    let parenName = tablePart.find('(')
    let tableName = (if parenName > 0: tablePart[0 ..< parenName] else: tablePart).strip()
    if tableName notin db.tables:
      return SdkResult[int].err(makeSdkErr(sdkErrNotFound, "Table not found: " & tableName))
    let valPart = rest[valsIdx + 6 .. ^1].strip()
    let openP = valPart.find('(')
    let closeP = valPart.rfind(')')
    if openP < 0 or closeP <= openP:
      return SdkResult[int].err(makeSdkErr(sdkErrInvalidInput, "Malformed VALUES (...)"))
    var row: SqliteRow = @[]
    for item in valPart[openP + 1 ..< closeP].split(','):
      var s = item.strip()
      if s.len >= 2 and ((s[0] == '\'' and s[^1] == '\'') or (s[0] == '"' and s[^1] == '"')):
        s = s[1 .. ^2]
      row.add(s)
    try:
      db.tables[tableName].rows.add(row)
    except KeyError:
      return SdkResult[int].err(makeSdkErr(sdkErrNotFound, "Table not found: " & tableName))
    return SdkResult[int].ok(1)
  SdkResult[int].err(makeSdkErr(sdkErrInvalidInput, "Unsupported SQL statement in minimal SDK store: " & trimmed))

proc querySqlite*(db: SqliteDb, tableName: string): SdkResult[SqliteQueryResult] {.raises: [].} =
  if not db.isOpen:
    return SdkResult[SqliteQueryResult].err(makeSdkErr(sdkErrInvalidInput, "SQLite database is closed"))
  try:
    if tableName notin db.tables:
      return SdkResult[SqliteQueryResult].err(makeSdkErr(sdkErrNotFound, "Table not found: " & tableName))
    SdkResult[SqliteQueryResult].ok(db.tables[tableName])
  except KeyError:
    SdkResult[SqliteQueryResult].err(makeSdkErr(sdkErrNotFound, "Table not found: " & tableName))

# =============================================================================
# 4. CSV Block (RFC 4180 parse/format; permFs for file I/O)
# =============================================================================

proc parseCsv*(content: string, delimiter: char = ','): SdkResult[seq[seq[string]]] {.raises: [].} =
  var rows: seq[seq[string]] = @[]
  var row: seq[string] = @[]
  var field = ""
  var inQuotes = false
  var i = 0
  while i < content.len:
    let ch = content[i]
    if inQuotes:
      if ch == '"':
        if i + 1 < content.len and content[i + 1] == '"':
          field.add('"')
          inc i
        else:
          inQuotes = false
      else:
        field.add(ch)
    else:
      if ch == '"':
        inQuotes = true
      elif ch == delimiter:
        row.add(field)
        field = ""
      elif ch == '\r':
        if i + 1 < content.len and content[i + 1] == '\n':
          inc i
        row.add(field)
        rows.add(row)
        row = @[]
        field = ""
      elif ch == '\n':
        row.add(field)
        rows.add(row)
        row = @[]
        field = ""
      else:
        field.add(ch)
    inc i
  if inQuotes:
    return SdkResult[seq[seq[string]]].err(makeSdkErr(sdkErrInvalidInput, "Unterminated quoted field in CSV"))
  if field.len > 0 or row.len > 0:
    row.add(field)
    rows.add(row)
  SdkResult[seq[seq[string]]].ok(rows)

proc formatCsv*(rows: openArray[seq[string]], delimiter: char = ','): string {.raises: [].} =
  var outStr = ""
  for rIdx, row in rows:
    if rIdx > 0:
      outStr.add('\n')
    for cIdx, cell in row:
      if cIdx > 0:
        outStr.add(delimiter)
      let needsQuote = delimiter in cell or '"' in cell or '\n' in cell or '\r' in cell
      if needsQuote:
        outStr.add('"')
        for ch in cell:
          if ch == '"':
            outStr.add("\"\"")
          else:
            outStr.add(ch)
        outStr.add('"')
      else:
        outStr.add(cell)
  outStr

proc readCsvFile*(policy: var PermissionPolicy, path: string, delimiter: char = ','): SdkResult[seq[seq[string]]] {.raises: [].} =
  let perm = policy.requirePermission(permFs, "csv:read", path)
  if perm.isErr:
    return SdkResult[seq[seq[string]]].err(perm.unwrapErr())
  try:
    let content = readFile(path)
    parseCsv(content, delimiter)
  except CatchableError as e:
    SdkResult[seq[seq[string]]].err(makeSdkErr(sdkErrIoFailure, "Failed to read CSV '" & path & "': " & e.msg, $permFs))

proc writeCsvFile*(policy: var PermissionPolicy, path: string, rows: openArray[seq[string]], delimiter: char = ','): SdkResult[void] {.raises: [].} =
  let perm = policy.requireFsWrite("csv:write", path)
  if perm.isErr:
    return perm
  try:
    writeFile(path, formatCsv(rows, delimiter))
    SdkResult[void].ok()
  except CatchableError as e:
    SdkResult[void].err(makeSdkErr(sdkErrIoFailure, "Failed to write CSV '" & path & "': " & e.msg, $permFs))

# =============================================================================
# 5. LocalStorage Block (bounded KV store; permFs for disk persistence)
# =============================================================================

type
  LocalStorage* = object
    appId*: string
    maxBytes*: int
    usedBytes*: int
    entries*: Table[string, string]

proc initLocalStorage*(appId: string, maxBytes: int = 1024 * 1024): LocalStorage {.raises: [].} =
  LocalStorage(
    appId: appId,
    maxBytes: max(1024, maxBytes),
    usedBytes: 0,
    entries: initTable[string, string]()
  )

proc setItem*(store: var LocalStorage, key, value: string): SdkResult[void] {.raises: [].} =
  if key.len == 0:
    return SdkResult[void].err(makeSdkErr(sdkErrInvalidInput, "LocalStorage key cannot be empty"))
  let prevLen =
    try:
      if key in store.entries: key.len + store.entries[key].len else: 0
    except KeyError:
      0
  let nextUsed = store.usedBytes - prevLen + key.len + value.len
  if nextUsed > store.maxBytes:
    return SdkResult[void].err(makeSdkErr(sdkErrQuotaExceeded, "LocalStorage quota exceeded (" & $store.maxBytes & " bytes)"))
  store.entries[key] = value
  store.usedBytes = nextUsed
  SdkResult[void].ok()

proc getItem*(store: LocalStorage, key: string): SdkResult[string] {.raises: [].} =
  try:
    if key notin store.entries:
      return SdkResult[string].err(makeSdkErr(sdkErrNotFound, "Key not found: " & key))
    SdkResult[string].ok(store.entries[key])
  except KeyError:
    SdkResult[string].err(makeSdkErr(sdkErrNotFound, "Key not found: " & key))

proc removeItem*(store: var LocalStorage, key: string): bool {.raises: [].} =
  try:
    if key notin store.entries:
      return false
    store.usedBytes -= (key.len + store.entries[key].len)
    store.entries.del(key)
    true
  except KeyError:
    false

proc clearStorage*(store: var LocalStorage) {.raises: [].} =
  store.entries.clear()
  store.usedBytes = 0

proc keys*(store: LocalStorage): seq[string] {.raises: [].} =
  for k in store.entries.keys:
    result.add(k)

proc saveLocalStorage*(store: LocalStorage, policy: var PermissionPolicy, path: string): SdkResult[void] {.raises: [].} =
  let perm = policy.requireFsWrite("local_storage:save", path)
  if perm.isErr:
    return perm
  var obj = newJObject()
  for k, v in store.entries.pairs:
    obj[k] = %v
  try:
    writeFile(path, $obj)
    SdkResult[void].ok()
  except CatchableError as e:
    SdkResult[void].err(makeSdkErr(sdkErrIoFailure, "Failed to persist LocalStorage: " & e.msg, $permFs))

# =============================================================================
# 6. Shell Block (permProcess + command allowlist, arg-array only)
# =============================================================================

type
  ShellRequest* = object
    command*: string
    args*: seq[string]
    workingDir*: string

  ShellResult* = object
    exitCode*: int
    output*: string

proc execShell*(policy: var PermissionPolicy, req: ShellRequest): SdkResult[ShellResult] {.raises: [].} =
  ## Executes a process strictly via command + args array (no shell interpolation),
  ## gated by `permProcess` and `allowedCommands`.
  let cmd = req.command.strip()
  if cmd.len == 0:
    return SdkResult[ShellResult].err(makeSdkErr(sdkErrInvalidInput, "Shell command cannot be empty"))
  let perm = policy.requireProcessCommand("shell:exec", cmd)
  if perm.isErr:
    return SdkResult[ShellResult].err(perm.unwrapErr())
  try:
    let prevDir = if req.workingDir.len > 0: getCurrentDir() else: ""
    if req.workingDir.len > 0:
      setCurrentDir(req.workingDir)
    defer:
      if prevDir.len > 0:
        try: setCurrentDir(prevDir)
        except CatchableError: discard
    let p = startProcess(cmd, args = req.args, options = {poUsePath, poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    SdkResult[ShellResult].ok(ShellResult(exitCode: code, output: output))
  except CatchableError as e:
    SdkResult[ShellResult].err(makeSdkErr(sdkErrProcessFailure, "Process execution failed: " & e.msg, $permProcess))
