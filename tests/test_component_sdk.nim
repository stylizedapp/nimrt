## Verification Suite for Item 11: NimUI Component SDK
## Covers:
## 1. Permission model (default-deny, explicit grant, allowlists, audit log)
## 2. Third-party block contract & SemVer compatibility
## 3. All 11 minimal UI blocks + layout computation
## 4. All 6 system blocks (HTTP, JSON, SQLite, CSV, LocalStorage, Shell)
## 5. Zero memory leaks under TrackingAllocator + ORC

import std/[json, strutils]
import corex/[allocators, result, slab, testing]
import nimui/[layout, dsl, sdk]
import nimui/gpu/font_atlas

proc testPermissions() =
  echo "[Suite 1] Component SDK Permissions & Audit Log"
  var policy = defaultPermissionPolicy()
  doAssert policy.granted == {}
  doAssert policy.readOnlyFs == true

  let parsed = parsePermissions("fs, network, clipboard")
  doAssert parsed.isOk
  doAssert permFs in parsed.unwrap()
  doAssert permNetwork in parsed.unwrap()
  doAssert permClipboard in parsed.unwrap()
  doAssert permProcess notin parsed.unwrap()

  let invalid = parsePermissions("fs, magic")
  doAssert invalid.isErr
  doAssert invalid.unwrapErr().kind == sdkErrInvalidInput

  # Default deny
  doAssert policy.requirePermission(permFs, "read", "data.txt").isErr
  doAssert policy.requirePermission(permClipboard, "write", "clip").isErr
  doAssert policy.auditLog.len == 2
  doAssert not policy.auditLog[0].allowed

  # Grant fs read-only -> write still denied
  policy.granted.incl(permFs)
  doAssert policy.requirePermission(permFs, "read", "data.txt").isOk
  doAssert policy.requireFsWrite("write", "data.txt").isErr

  policy.readOnlyFs = false
  doAssert policy.requireFsWrite("write", "data.txt").isOk
  echo "  [OK] Permissions & audit log verified"

proc testContractAndVersioning() =
  echo "[Suite 2] Third-Party Block Contract & SemVer Compatibility"
  let v010 = parseSemVer("0.1.0").unwrap()
  let v012 = parseSemVer("0.1.2").unwrap()
  let v020 = parseSemVer("0.2.0").unwrap()
  let v100 = parseSemVer("1.0.0").unwrap()
  let v120 = parseSemVer("1.2.0").unwrap()

  doAssert v012.isCompatibleWith(v010)
  doAssert not v010.isCompatibleWith(v012)
  doAssert not v020.isCompatibleWith(v010)
  doAssert v120.isCompatibleWith(v100)
  doAssert not v100.isCompatibleWith(v120)

  var reg = initBlockRegistry(SDK_API_VERSION)
  let okManifest = BlockManifest(
    id: "com.example.chart",
    name: "Chart",
    version: v010,
    minSdkVersion: v010,
    kind: bkUi,
    requiredPermissions: {permFs},
    propsSchema: @[
      PropSpec(name: "data", propType: ptList, required: true, defaultValue: "[]")
    ]
  )
  doAssert reg.registerBlock(okManifest).isOk
  doAssert reg.registerBlock(okManifest).isErr # duplicate

  let badSdkManifest = BlockManifest(
    id: "com.example.future",
    name: "Future",
    version: v020,
    minSdkVersion: v020,
    kind: bkSystem,
    requiredPermissions: {}
  )
  let badReg = reg.registerBlock(badSdkManifest)
  doAssert badReg.isErr
  doAssert badReg.unwrapErr().kind == sdkErrIncompatibleVersion

  var policy = defaultPermissionPolicy()
  let deniedCall = reg.checkBlockInvocation("com.example.chart", policy)
  doAssert deniedCall.isErr
  doAssert deniedCall.unwrapErr().kind == sdkErrPermissionDenied

  policy.granted.incl(permFs)
  let allowedCall = reg.checkBlockInvocation("com.example.chart", policy)
  doAssert allowedCall.isOk
  echo "  [OK] Contract & SemVer compatibility verified"

proc testUiBlocks() =
  echo "[Suite 3] 11 Minimal UI Blocks + Flexbox Layout"
  let atlas = initFontAtlas("Segoe UI", 16.0f)
  var tree = initUiTree()
  defer: tree.destroy()
  let root = VStack(tree, padding = 12.0f, gap = 8.0f, width = fixed(800.0f), height = fixed(600.0f))
  tree.rootId = root

  # 1. Text, 2. Button, 3. Input, 4. List
  let txtId = sdkText(tree, root, "Hello SDK")
  let btnId = sdkButton(tree, root, "Run")
  let inpId = sdkInput(tree, root, placeholder = "Type here...")
  let listId = sdkList(tree, root, count = 100)
  doAssert tree.nodes[txtId].text == "Hello SDK"
  doAssert tree.nodes[btnId].text == "Run"
  doAssert tree.nodes[inpId].placeholder == "Type here..."
  doAssert tree.nodes[listId].virtualCount == 100

  # 5. Table
  let tbl = sdkTable(
    tree, root,
    columns = @[
      TableColumn(key: "name", title: "Name", width: 160.0f),
      TableColumn(key: "size", title: "Size", width: 80.0f)
    ],
    rows = @[
      @["main.nim", "4 KB"],
      @["sdk.nim", "2 KB"]
    ]
  )
  doAssert tbl.columns.len == 2
  doAssert tbl.rows.len == 2

  # 6. Image
  let imgId = sdkImage(tree, root, src = "assets/logo.png", alt = "NimRT Logo", width = 64.0f, height = 64.0f)
  doAssert tree.nodes[imgId].placeholder == "assets/logo.png"

  # 7. Tabs
  var tabs = sdkTabs(tree, root, @["Overview", "Settings"])
  doAssert tabs.activeIndex == 0
  doAssert tabs.switchTab(tree, 1).isOk
  doAssert tabs.activeIndex == 1
  doAssert tabs.switchTab(tree, 5).isErr

  # 8. Modal
  var modal = sdkModal(tree, root, "Confirm", isOpen = false)
  doAssert not modal.isOpen
  modal.setModalOpen(tree, true)
  doAssert modal.isOpen

  # 9. Toast (OS notification permission check)
  var policy = defaultPermissionPolicy()
  var osToast = sdkToast(tree, root, osNotification = true)
  doAssert osToast.showToast(tree, policy, "Alert").isErr
  policy.granted.incl(permNotifications)
  doAssert osToast.showToast(tree, policy, "Saved!", tlSuccess, durationMs = 1000).isOk
  doAssert osToast.visible
  osToast.tickToast(tree, 1000)
  doAssert not osToast.visible

  # 10. FilePicker (fs permission check)
  var picker = sdkFilePicker(tree, root, mode = fpOpenFile)
  doAssert picker.pickFile(tree, policy, "C:\\temp\\test.txt").isErr
  policy.granted.incl(permFs)
  doAssert picker.pickFile(tree, policy, "C:\\temp\\test.txt").isOk
  doAssert picker.selectedPath == "C:\\temp\\test.txt"

  # 11. Timer
  var ticks = 0
  var timer = sdkTimer(intervalMs = 100, repeat = true, autoStart = true, onTick = proc(c: int) =
    ticks = c
  )
  doAssert timer.tick(250) == 2
  doAssert ticks == 2
  timer.stop()
  doAssert timer.tick(200) == 0

  tree.layoutTree(800.0f, 600.0f, atlas)
  doAssert tree.nodes[root].computedRect.w == 800.0f
  echo "  [OK] All 11 UI blocks verified"

proc testSystemBlocks() =
  echo "[Suite 4] 6 System Blocks (HTTP, JSON, SQLite, CSV, LocalStorage, Shell)"
  var policy = defaultPermissionPolicy()

  # 1. HTTP
  let mockTransport: HttpTransportProc = proc(req: HttpRequest): SdkResult[HttpResponse] =
    SdkResult[HttpResponse].ok(HttpResponse(status: 200, headers: @[], body: "ok:" & $req.httpMethod))
  let req = HttpRequest(httpMethod: hmGet, url: "https://api.example.com/v1/ping")
  doAssert execHttp(policy, req, mockTransport).isErr # denied
  policy.granted.incl(permNetwork)
  policy.allowedHosts = @["other.example.com"]
  doAssert execHttp(policy, req, mockTransport).isErr # host not in allowlist
  policy.allowedHosts.add("api.example.com")
  let httpRes = execHttp(policy, req, mockTransport)
  doAssert httpRes.isOk
  doAssert httpRes.unwrap().status == 200

  # 2. JSON
  let jRes = jsonParse("""{"sdk":"nimui","version":1}""")
  doAssert jRes.isOk
  doAssert jRes.unwrap()["sdk"].getStr() == "nimui"
  doAssert jsonStringify(jRes.unwrap()).isOk
  doAssert jsonParse("{bad json").isErr

  # 3. SQLite
  doAssert openSqlite(policy, SqliteConfig(path: "test.db", readOnly: false)).isErr # fs denied
  var db = openSqlite(policy, SqliteConfig(path: ":memory:")).unwrap()
  doAssert db.execSqlite("CREATE TABLE items (id, name)").isOk
  doAssert db.execSqlite("INSERT INTO items VALUES ('1', 'alpha')").isOk
  let q = db.querySqlite("items").unwrap()
  doAssert q.rows.len == 1
  doAssert q.rows[0] == @["1", "alpha"]
  db.closeSqlite()

  # 4. CSV
  let csvRows = parseCsv("name,role\n\"alice, bob\",admin\n").unwrap()
  doAssert csvRows.len == 2
  doAssert csvRows[1][0] == "alice, bob"
  let formatted = formatCsv(csvRows)
  doAssert "\"alice, bob\"" in formatted
  doAssert readCsvFile(policy, "nonexistent.csv").isErr # fs denied

  # 5. LocalStorage
  var store = initLocalStorage("com.nimrt.test", maxBytes = 1024)
  doAssert store.setItem("theme", "monochrome").isOk
  doAssert store.getItem("theme").unwrap() == "monochrome"
  var bigVal = newString(2000)
  doAssert store.setItem("big", bigVal).isErr # quota exceeded
  doAssert store.removeItem("theme")
  doAssert store.getItem("theme").isErr

  # 6. Shell
  let shReq = ShellRequest(command: "cmd", args: @["/c", "echo", "hello"])
  doAssert execShell(policy, shReq).isErr # process denied
  policy.granted.incl(permProcess)
  policy.allowedCommands = @["nim"]
  doAssert execShell(policy, shReq).isErr # command not allowlisted
  policy.allowedCommands.add("cmd")
  let shRes = execShell(policy, shReq)
  doAssert shRes.isOk
  doAssert shRes.unwrap().exitCode == 0
  doAssert "hello" in shRes.unwrap().output
  echo "  [OK] All 6 system blocks verified"

when isMainModule:
  testPermissions()
  testContractAndVersioning()
  testUiBlocks()
  testSystemBlocks()

  testWithLeakCheck("Component SDK zero-leak check"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    let root = VStack(tree, width = fixed(400.0f), height = fixed(300.0f))
    tree.rootId = root
    discard sdkText(tree, root, "Leak check")
    discard sdkButton(tree, root, "Click")
    var policy = defaultPermissionPolicy()
    policy.granted = {permFs, permNetwork}
    discard parsePermissions("fs,network")
  echo "[PASS] Component SDK verification suite passed (0 leaks)"
