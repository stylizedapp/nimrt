## apps/everything/src/config — Everything-Nim Application Configuration & Persistence
##
## Manages persistent user configuration (%APPDATA%\everything-nim\config.json),
## hotkey parsing, first-launch indexing prompts, and index path resolution.

import std/[os, json, strutils, widestrs]

when defined(windows):
  type
    HWND = pointer
    UINT = uint32

  proc messageBoxW(hWnd: HWND, lpText: WideCString, lpCaption: WideCString, uType: UINT): int32 {.
    stdcall, dynlib: "user32", importc: "MessageBoxW", sideEffect.}

  const
    MB_YESNO* = 0x00000004'u32
    MB_ICONQUESTION* = 0x00000020'u32
    IDYES* = 6
    IDNO* = 7

const
  # Win32 Modifier Keys for RegisterHotKey
  MOD_ALT* = 0x0001'u32
  MOD_CONTROL* = 0x0002'u32
  MOD_SHIFT* = 0x0004'u32
  MOD_WIN* = 0x0008'u32
  MOD_NOREPEAT* = 0x4000'u32

  # Win32 Virtual Keys
  VK_BACK* = 0x08'u32
  VK_TAB* = 0x09'u32
  VK_RETURN* = 0x0D'u32
  VK_ESCAPE* = 0x1B'u32
  VK_SPACE* = 0x20'u32
  VK_F1* = 0x70'u32

type
  Config* = object
    hotkey*: string
    autosync*: bool
    drives*: seq[string]
    indexPath*: string

proc getAppDataDir*(): string =
  let appData = getEnv("APPDATA")
  if appData.len > 0:
    appData
  else:
    getHomeDir() / "AppData" / "Roaming"

proc getDefaultConfigDir*(): string =
  getAppDataDir() / "everything-nim"

proc getDefaultConfigPath*(): string =
  getDefaultConfigDir() / "config.json"

proc getDefaultIndexPath*(): string =
  getTempDir() / "everything.idx"

proc getGuiLogPath*(): string =
  getTempDir() / "everything-nim" / "gui.log"

proc ensureAppDirectories*() =
  try:
    let cfgDir = getDefaultConfigDir()
    if not dirExists(cfgDir):
      createDir(cfgDir)
    let logDir = getTempDir() / "everything-nim"
    if not dirExists(logDir):
      createDir(logDir)
  except CatchableError:
    discard

proc defaultConfig*(): Config =
  Config(
    hotkey: "Win+E",
    autosync: true,
    drives: @["C:"],
    indexPath: getDefaultIndexPath()
  )

proc parseHotkey*(hotkeyStr: string): tuple[modifiers: uint32, key: uint32] =
  ## Parses human-readable hotkey strings such as "Win+E", "Ctrl+Alt+Space", "Ctrl+Shift+F"
  var mods: uint32 = MOD_NOREPEAT
  var key: uint32 = 0

  let tokens = hotkeyStr.split('+')
  for rawToken in tokens:
    let token = rawToken.strip()
    let tokenUpper = token.toUpperAscii()

    case tokenUpper
    of "WIN", "WINDOWS", "SUPER":
      mods = mods or MOD_WIN
    of "CTRL", "CONTROL":
      mods = mods or MOD_CONTROL
    of "ALT", "MENU":
      mods = mods or MOD_ALT
    of "SHIFT":
      mods = mods or MOD_SHIFT
    of "SPACE":
      key = VK_SPACE
    of "ENTER", "RETURN":
      key = VK_RETURN
    of "TAB":
      key = VK_TAB
    of "ESC", "ESCAPE":
      key = VK_ESCAPE
    else:
      if tokenUpper.startsWith("F") and tokenUpper.len >= 2:
        try:
          let fNum = parseInt(tokenUpper[1 .. ^1])
          if fNum >= 1 and fNum <= 24:
            key = VK_F1 + uint32(fNum - 1)
        except ValueError:
          discard
      elif token.len == 1:
        let ch = tokenUpper[0]
        if ch in {'A'..'Z', '0'..'9'}:
          key = uint32(ord(ch))

  (mods, key)

proc toJson*(cfg: Config): JsonNode =
  %*{
    "hotkey": cfg.hotkey,
    "autosync": cfg.autosync,
    "drives": cfg.drives,
    "indexPath": cfg.indexPath
  }

proc fromJson*(node: JsonNode): Config =
  result = defaultConfig()
  if node.isNil or node.kind != JObject:
    return result

  if node.hasKey("hotkey") and node["hotkey"].kind == JString:
    result.hotkey = node["hotkey"].getStr()
  if node.hasKey("autosync") and node["autosync"].kind == JBool:
    result.autosync = node["autosync"].getBool()
  if node.hasKey("drives") and node["drives"].kind == JArray:
    var drives: seq[string] = @[]
    for item in node["drives"].elems:
      if item.kind == JString:
        drives.add(item.getStr())
    if drives.len > 0:
      result.drives = drives
  if node.hasKey("indexPath") and node["indexPath"].kind == JString:
    result.indexPath = node["indexPath"].getStr()

proc loadConfig*(path: string = ""): Config =
  ensureAppDirectories()
  let targetPath = if path.len > 0: path else: getDefaultConfigPath()
  if not fileExists(targetPath):
    return defaultConfig()

  try:
    let content = readFile(targetPath)
    let jsonNode = parseJson(content)
    result = fromJson(jsonNode)
    if not isAbsolute(result.indexPath):
      result.indexPath = getDefaultIndexPath()
  except CatchableError:
    result = defaultConfig()

proc saveConfig*(cfg: Config, path: string = ""): bool =
  ensureAppDirectories()
  let targetPath = if path.len > 0: path else: getDefaultConfigPath()
  try:
    let dir = splitFile(targetPath).dir
    if dir.len > 0 and not dirExists(dir):
      createDir(dir)
    let jsonStr = pretty(toJson(cfg))
    writeFile(targetPath, jsonStr)
    true
  except CatchableError:
    false

proc checkFirstLaunch*(cfg: var Config, promptUser: bool = true): bool =
  ## Checks if the index file exists. If missing, prompts the user to initialize index.
  ## Returns true if indexing should proceed, false if skipped/cancelled.
  if fileExists(cfg.indexPath):
    return false # Already indexed, not first launch

  if not promptUser:
    return true # In non-interactive mode, default to proceed

  when defined(windows):
    let driveStr = if cfg.drives.len > 0: cfg.drives[0] else: "C:"
    let msg = "No Everything index was found at:\n" & cfg.indexPath &
              "\n\nWould you like to build an initial index for " & driveStr & " now?"
    let title = "Everything-Nim - First Launch"
    let wMsg = newWideCString(msg)
    let wTitle = newWideCString(title)

    let response = messageBoxW(nil, wMsg, wTitle, MB_YESNO or MB_ICONQUESTION)
    return response == IDYES
  else:
    return true
