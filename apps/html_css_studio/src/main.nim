## =============================================================================
## NimUI HTML5/CSS3 Zero-JS Studio — Test-Case Showcase Application 1
##
## Demonstrates:
## - Pure-Nim HTML5 + CSS3 engine (zero JS, strict <script>/on* rejection)
## - HtmlBindingRegistry + ReactiveRuntime signals (data-click, data-text, data-bind)
## - Hybrid HTML5/CSS3 shells + Native NimUI Controls & 1,000,000-row VirtualList
## - Both interactive Vulkan 1.1+ window (1360x860) and --headless-test / --export-screenshots
## =============================================================================

import std/[os, strformat, strutils]
import corex
import corex/signals
import nimui
import nimui/controls
import nimui/window
import nimui/gpu/[vulkan_backend, font_atlas]

const
  StudioWidth = 1360
  StudioHeight = 860

  ColBgPage      = 0x0A0A0CFF'u32
  ColBgSurface   = 0x121216FF'u32
  ColBgRaised    = 0x1A1A20FF'u32
  ColBorder      = 0x24242CFF'u32
  ColTextPrim    = 0xF4F4F6FF'u32
  ColTextSec     = 0x94A3B8FF'u32

  SampleValidHtml = """
    <style>
      .demo-card {
        background-color: #132A24;
        border: 1px solid #10B981;
        border-radius: 8px;
        padding: 12px;
        gap: 6px;
      }
      .demo-title { color: #34D399; font-size: 15px; }
      .demo-body { color: #E2E8F0; font-size: 13px; }
    </style>
    <div class="demo-card">
      <h3 class="demo-title">Verified Pure-Nim Fragment</h3>
      <p class="demo-body">Rendered safely with Zero-JS HTML5/CSS3 cascade.</p>
    </div>
  """

  SampleScriptHtml = """<div class="card"><script>alert("XSS")</script><p>Malicious</p></div>"""
  SampleOnClickHtml = """<div class="card"><button onclick="stealToken()">Click Me</button></div>"""
  SampleJsUriHtml = """<div class="card"><a href="javascript:eval(1)">Unsafe Link</a></div>"""

type
  StudioApp = ref object
    alloc: Allocator
    fontAtlas: FontAtlas
    tree: UiTree
    rt: ReactiveRuntime
    bindings: HtmlBindingRegistry

    activeTab: int
    pendingTab: int
    needsRebuild: bool

    # Tab 0: Telemetry Dashboard state
    rpsVal: int
    p99Ms: float32
    activeSignals: int
    accentIdx: int

    # Tab 1: Forms & Controls state
    userName: string
    userRole: string
    tagQuery: string
    autoSave: bool
    enableTelemetry: bool
    enableNotify: bool
    deployEnvIdx: int
    workerThreads: float32
    memBudgetMb: float32
    regionIdx: int
    configNotesArea: TextArea
    notesHostBox: SlabId

    # Tab 2: Zero-JS Security Sandbox state
    sandboxSampleIdx: int
    sandboxVerdict: string
    sandboxStats: string
    sandboxDetail: string
    sandboxAllowed: bool
    sandboxMountedHtml: string
    sandboxPreviewBox: SlabId
    sandboxVerdictCard: SlabId

    # Tab 3: 1M-Row Virtual Explorer state
    gridQuery: string
    gridFilterMode: int
    virtualCount: int
    selectedRowIdx: int
    virtualListId: SlabId

    # Live signals for current scene
    globalStatusSig: Signal[string]
    rpsSig: Signal[string]
    p99Sig: Signal[string]
    leaksSig: Signal[string]
    signalsCountSig: Signal[string]

    userNameSig: Signal[string]
    userRoleSig: Signal[string]
    tagQuerySig: Signal[string]
    profileSummarySig: Signal[string]

    sandboxVerdictSig: Signal[string]
    sandboxStatsSig: Signal[string]
    sandboxDetailSig: Signal[string]

    gridQuerySig: Signal[string]
    gridStatusSig: Signal[string]

proc regionNames(): array[4, string] {.raises: [].} =
  ["eu-central-1 (Frankfurt)", "us-east-1 (Virginia)", "ap-northeast-1 (Tokyo)", "local-sandbox (Zero-Net)"]

proc deployEnvNames(): array[3, string] {.raises: [].} =
  ["Production Cluster", "Staging Canary", "Local Bare-Metal"]

proc updateProfileSummaryText(app: StudioApp): string {.raises: [].} =
  let envName = deployEnvNames()[clamp(app.deployEnvIdx, 0, 2)]
  let saveTag = if app.autoSave: "AutoSave:ON" else: "AutoSave:OFF"
  app.userName & " (" & app.userRole & ") • " & envName & " • " &
    $int(app.workerThreads) & "T/" & $int(app.memBudgetMb) & "MB • " & saveTag

proc evalSandboxCase(app: StudioApp, caseIdx: int) {.raises: [].} =
  app.sandboxSampleIdx = caseIdx
  let snippet = case caseIdx
    of 0: SampleValidHtml
    of 1: SampleScriptHtml
    of 2: SampleOnClickHtml
    else: SampleJsUriHtml

  let parsed = parseHtmlDoc(snippet)
  if parsed.isOk():
    let doc = parsed.get()
    let sheet = parseCssSheet(doc.embeddedCss)
    app.sandboxAllowed = true
    app.sandboxVerdict = "ALLOWED — Pure-Nim Zero-JS DOM Verified"
    app.sandboxStats = "HTML Nodes: " & $doc.nodes.len & " | CSS Rules: " & $sheet.rules.len & " | JS Threats: 0"
    app.sandboxDetail = "Parsed safely cleanly into UiTree with embedded CSS3 styles."
    app.sandboxMountedHtml = snippet
  else:
    app.sandboxAllowed = false
    app.sandboxVerdict = "REJECTED — Zero-JS Security Policy Enforced"
    app.sandboxStats = "Blocked Threat | Script Execution Prevented (0 bytes eval'd)"
    app.sandboxDetail = parsed.error()
    app.sandboxMountedHtml = ""

proc applyVirtualFilter(app: StudioApp, rebuildList: bool = true) {.raises: [].} =
  let q = app.gridQuery.strip().toLowerAscii()
  if q.len > 0:
    app.virtualCount = 25_000
  else:
    case app.gridFilterMode
    of 0: app.virtualCount = 1_000_000
    of 1: app.virtualCount = 142_857
    else: app.virtualCount = 250_000
  if app.selectedRowIdx >= app.virtualCount:
    app.selectedRowIdx = 0
  if rebuildList and app.virtualListId != SlabId(-1) and app.tree.nodes.contains(app.virtualListId):
    app.tree.nodes[app.virtualListId].virtualCount = app.virtualCount
    app.tree.nodes[app.virtualListId].selectedIndex = app.selectedRowIdx
    app.tree.isLayoutDirty = true
    app.tree.isDirty = true
  let modeLabel = case app.gridFilterMode
    of 0: "All Records"
    of 1: "Critical/Error Filter"
    else: "GPU Compute Nodes"
  let summary = modeLabel & ": " & $app.virtualCount & " virtual rows | Selected #" & $app.selectedRowIdx &
    (if q.len > 0: " | Query: '" & app.gridQuery & "'" else: "")
  if app.gridStatusSig.runtime != nil:
    app.gridStatusSig.set(summary)

proc formatNumberComma(n: int): string {.raises: [].} =
  let s = $n
  result = ""
  var count = 0
  for i in countdown(s.len - 1, 0):
    if count > 0 and (count mod 3 == 0):
      result = "," & result
    result = $s[i] & result
    inc count

proc makeTabClickProc(app: StudioApp, tabIdx: int): HtmlClickProc {.raises: [].} =
  result = proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      if app.activeTab != tabIdx:
        app.pendingTab = tabIdx
        app.needsRebuild = true

proc makeSandboxClickProc(app: StudioApp, caseIdx: int): HtmlClickProc {.raises: [].} =
  result = proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.evalSandboxCase(caseIdx)
      app.pendingTab = 2
      app.needsRebuild = true

proc rebuildScene*(app: StudioApp) {.raises: [].} =
  resetControls()
  app.bindings.destroy()
  app.tree.destroy()
  app.rt.destroy()

  app.tree = initUiTree(app.alloc)
  app.rt = initReactiveRuntime(app.alloc)
  app.bindings = initHtmlBindingRegistry()
  app.notesHostBox = SlabId(-1)
  app.sandboxPreviewBox = SlabId(-1)
  app.sandboxVerdictCard = SlabId(-1)
  app.virtualListId = SlabId(-1)

  # Initialize scene signals from durable app state
  let tabNames = ["Dashboard", "Forms & Controls", "Zero-JS Sandbox", "1M Virtual Data"]
  app.globalStatusSig = app.rt.createSignal("Active Scene: " & tabNames[app.activeTab] & " | ORC 0-Leak")
  app.rpsSig = app.rt.createSignal(formatNumberComma(app.rpsVal) & " req/s")
  app.p99Sig = app.rt.createSignal(&"{app.p99Ms:.2f} ms")
  app.leaksSig = app.rt.createSignal("0 bytes")
  app.signalsCountSig = app.rt.createSignal($app.activeSignals & " active")

  app.userNameSig = app.rt.createSignal(app.userName)
  app.userRoleSig = app.rt.createSignal(app.userRole)
  app.tagQuerySig = app.rt.createSignal(app.tagQuery)
  app.profileSummarySig = app.rt.createSignal(app.updateProfileSummaryText())

  app.sandboxVerdictSig = app.rt.createSignal(app.sandboxVerdict)
  app.sandboxStatsSig = app.rt.createSignal(app.sandboxStats)
  app.sandboxDetailSig = app.rt.createSignal(app.sandboxDetail)

  app.gridQuerySig = app.rt.createSignal(app.gridQuery)
  app.gridStatusSig = app.rt.createSignal("")

  # Common top bar tab switch handlers
  for i in 0 ..< 4:
    app.bindings.onClick("tab-" & $i, makeTabClickProc(app, i))
  app.bindings.bindTextSignal("global-status", app.globalStatusSig)

  let rootId = app.tree.createNode(nkBox)
  app.tree.rootId = rootId
  app.tree.nodes[rootId].direction = fdColumn
  app.tree.nodes[rootId].widthMode = flexGrow()
  app.tree.nodes[rootId].heightMode = flexGrow()
  app.tree.nodes[rootId].alignItems = aiStretch
  app.tree.nodes[rootId].bgColor = ColBgPage
  app.tree.nodes[rootId].padding = [12.0f, 12.0f, 12.0f, 12.0f]
  app.tree.nodes[rootId].gap = 10.0f

  # Mount Top Header + Navigation via HTML5/CSS3
  var navClasses: array[4, string]
  for i in 0 ..< 4:
    navClasses[i] = if i == app.activeTab: "nav-btn active" else: "nav-btn"

  let headerHtml = """
    <style>
      .studio-header {
        display: flex;
        flex-direction: row;
        align-items: center;
        justify-content: space-between;
        width: 100%;
        padding: 10px 14px;
        background-color: #121216;
        border: 1px solid #24242C;
        border-radius: 8px;
        gap: 14px;
      }
      .brand-col {
        display: flex;
        flex-direction: column;
        gap: 2px;
      }
      .brand-title { color: #F8FAFC; font-size: 16px; }
      .brand-sub { color: #64748B; font-size: 11px; }
      .nav-row {
        display: flex;
        flex-direction: row;
        gap: 8px;
        align-items: center;
      }
      .nav-btn {
        background-color: #1A1A22;
        border: 1px solid #2E2E3A;
        border-radius: 6px;
        padding: 6px 14px;
        color: #CBD5E1;
        font-size: 13px;
        height: 32px;
      }
      .nav-btn:hover {
        background-color: #252532;
        border-color: #4F46E5;
      }
      .nav-btn.active {
        background-color: #312E81;
        border: 1px solid #6366F1;
        color: #FFFFFF;
      }
      .status-pill {
        background-color: #132A24;
        border: 1px solid #10B981;
        border-radius: 6px;
        padding: 5px 10px;
        color: #34D399;
        font-size: 12px;
      }
    </style>
    <div class="studio-header">
      <div class="brand-col">
        <span class="brand-title">NimUI HTML5/CSS3 Studio</span>
        <span class="brand-sub">Pure-Nim Zero-JS Engine + Reactive CoreX</span>
      </div>
      <div class="nav-row">
        <button id="btn-tab-0" class="""" & navClasses[0] & """" data-click="tab-0">1. Telemetry Dashboard</button>
        <button id="btn-tab-1" class="""" & navClasses[1] & """" data-click="tab-1">2. Forms & Controls</button>
        <button id="btn-tab-2" class="""" & navClasses[2] & """" data-click="tab-2">3. Zero-JS Sandbox</button>
        <button id="btn-tab-3" class="""" & navClasses[3] & """" data-click="tab-3">4. 1M Virtual Explorer</button>
      </div>
      <div class="status-pill" data-text="global-status">Ready</div>
    </div>
  """
  discard mountHtmlString(app.tree, addr app.rt, headerHtml, "", app.bindings, rootId)

  # Scene Body Host
  let bodyHost = Box(
    app.tree, rootId,
    direction = fdColumn,
    width = flexGrow(),
    height = flexGrow(),
    gap = 10.0f
  )
  app.tree.nodes[bodyHost].alignItems = aiStretch

  case app.activeTab
  of 0:
    # =========================================================================
    # SCENE 1: Cloud & System Telemetry Dashboard (Pure HTML5 + CSS3)
    # =========================================================================
    app.bindings.onClick("sim-spike", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.rpsVal += 24_500
        app.p99Ms = max(0.18f, app.p99Ms + 0.14f)
        app.activeSignals += 2
        app.rpsSig.set(formatNumberComma(app.rpsVal) & " req/s")
        app.p99Sig.set(&"{app.p99Ms:.2f} ms")
        app.signalsCountSig.set($app.activeSignals & " active")
        app.globalStatusSig.set("Spike simulated: " & formatNumberComma(app.rpsVal) & " req/s")
    )
    app.bindings.onClick("run-audit", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.leaksSig.set("0 B (ORC Verified)")
        app.p99Ms = max(0.24f, app.p99Ms * 0.85f)
        app.p99Sig.set(&"{app.p99Ms:.2f} ms")
        app.globalStatusSig.set("Memory audit passed: 0 leaked bytes")
    )
    app.bindings.onClick("cycle-accent", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.accentIdx = (app.accentIdx + 1) mod 3
        let names = ["Indigo", "Emerald", "Amber"]
        app.globalStatusSig.set("Theme Accent: " & names[app.accentIdx])
    )
    app.bindings.onClick("reset-metrics", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.rpsVal = 128_450
        app.p99Ms = 0.42f
        app.activeSignals = 18
        app.rpsSig.set("128,450 req/s")
        app.p99Sig.set("0.42 ms")
        app.leaksSig.set("0 bytes")
        app.signalsCountSig.set("18 active")
        app.globalStatusSig.set("Metrics reset to baseline")
    )

    app.bindings.bindTextSignal("kpi-rps", app.rpsSig)
    app.bindings.bindTextSignal("kpi-p99", app.p99Sig)
    app.bindings.bindTextSignal("kpi-leaks", app.leaksSig)
    app.bindings.bindTextSignal("kpi-signals", app.signalsCountSig)

    let accentColors = ["#6366F1", "#10B981", "#F59E0B"]
    let hiBorder = accentColors[app.accentIdx mod 3]

    let dashHtml = """
      <style>
        .dash-root {
          display: flex;
          flex-direction: column;
          width: 100%;
          gap: 12px;
          flex: 1;
        }
        .kpi-grid {
          display: flex;
          flex-direction: row;
          gap: 12px;
          height: 112px;
        }
        .kpi-card {
          flex: 1;
          background-color: #121216;
          border: 1px solid #24242C;
          border-radius: 8px;
          padding: 14px;
          gap: 6px;
        }
        .kpi-card.highlight {
          background-color: #171726;
          border: 2px solid """ & hiBorder & """;
        }
        .kpi-label { color: #94A3B8; font-size: 12px; }
        .kpi-value { color: #F8FAFC; font-size: 24px; }
        .kpi-sub { color: #10B981; font-size: 11px; }
        .toolbar-row {
          display: flex;
          flex-direction: row;
          gap: 10px;
          padding: 10px 14px;
          background-color: #121216;
          border: 1px solid #24242C;
          border-radius: 8px;
          align-items: center;
        }
        .act-btn {
          background-color: #1E293B;
          border: 1px solid #334155;
          border-radius: 6px;
          padding: 7px 14px;
          color: #F8FAFC;
          font-size: 13px;
          height: 34px;
        }
        .act-btn:hover { background-color: #334155; border-color: #64748B; }
        .act-btn.primary { background-color: #4F46E5; border-color: #6366F1; }
        .act-btn.primary:hover { background-color: #4338CA; }
        .panels-row {
          display: flex;
          flex-direction: row;
          gap: 12px;
          flex: 1;
        }
        .panel {
          flex: 1;
          background-color: #121216;
          border: 1px solid #24242C;
          border-radius: 8px;
          padding: 14px;
          gap: 8px;
        }
        .panel-hdr { color: #F8FAFC; font-size: 15px; }
        .panel > .metric-row {
          display: flex;
          flex-direction: row;
          justify-content: space-between;
          align-items: center;
          padding: 8px 10px;
          background-color: #18181E;
          border: 1px solid #22222A;
          border-radius: 6px;
        }
        .svc-name { color: #E2E8F0; font-size: 13px; }
        .svc-ok { color: #10B981; font-size: 12px; }
        .svc-info { color: #60A5FA; font-size: 12px; }
      </style>
      <div class="dash-root">
        <div class="kpi-grid">
          <div class="kpi-card highlight">
            <span class="kpi-label">THROUGHPUT (PURE NIM)</span>
            <span id="kpi-rps" class="kpi-value" data-text="kpi-rps">128,450 req/s</span>
            <span class="kpi-sub">Zero JS overhead • Flat SoA + Slab</span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">LAYOUT + DRAW P99</span>
            <span id="kpi-p99" class="kpi-value" data-text="kpi-p99">0.42 ms</span>
            <span class="kpi-sub">Target &lt; 0.50 ms / 1M items</span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">ORC MEMORY AUDIT</span>
            <span id="kpi-leaks" class="kpi-value" data-text="kpi-leaks">0 bytes</span>
            <span class="kpi-sub">TrackingAllocator verified</span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">REACTIVE GRAPH</span>
            <span id="kpi-signals" class="kpi-value" data-text="kpi-signals">18 active</span>
            <span class="kpi-sub">Fine-grained Signal&lt;T&gt; DAG</span>
          </div>
        </div>

        <div class="toolbar-row">
          <button id="btn-spike" class="act-btn primary" data-click="sim-spike">Simulate Load Spike</button>
          <button id="btn-audit" class="act-btn" data-click="run-audit">Run Memory Audit</button>
          <button id="btn-accent" class="act-btn" data-click="cycle-accent">Cycle Accent Border</button>
          <button id="btn-reset" class="act-btn" data-click="reset-metrics">Reset Baseline</button>
        </div>

        <div class="panels-row">
          <div class="panel">
            <h3 class="panel-hdr">CoreX &amp; NimUI Subsystem Status</h3>
            <div class="metric-row">
              <span class="svc-name">corex/io &amp; Win32 MFT</span>
              <span class="svc-ok">ONLINE (0 leaks)</span>
            </div>
            <div class="metric-row">
              <span class="svc-name">corex/unicode UTF-8 Runes</span>
              <span class="svc-ok">ACTIVE (std-independent)</span>
            </div>
            <div class="metric-row">
              <span class="svc-name">algx/swissmap Open Addressing</span>
              <span class="svc-ok">OPTIMAL (O(1) lookup)</span>
            </div>
            <div class="metric-row">
              <span class="svc-name">nimui/html_css Cascade Engine</span>
              <span class="svc-info">ZERO-JS ENFORCED</span>
            </div>
          </div>

          <div class="panel">
            <h3 class="panel-hdr">CSS3 Selector &amp; Layout Architecture</h3>
            <div class="metric-row">
              <span class="svc-name">Specificity Cascade</span>
              <span class="svc-info">#id(10000) &gt; .cls(100) &gt; tag(1)</span>
            </div>
            <div class="metric-row">
              <span class="svc-name">Combinators &amp; Pseudo</span>
              <span class="svc-ok">.a .b, .a &gt; .b, :hover, :active</span>
            </div>
            <div class="metric-row">
              <span class="svc-name">Vulkan 1.1+ Instanced SDF</span>
              <span class="svc-info">64B aligned UiDrawInstance</span>
            </div>
            <div class="metric-row">
              <span class="svc-name">Headless PNG Rasterizer</span>
              <span class="svc-ok">RFC 1950 Stored Deflate</span>
            </div>
          </div>
        </div>
      </div>
    """
    discard mountHtmlString(app.tree, addr app.rt, dashHtml, "", app.bindings, bodyHost)

  of 1:
    # =========================================================================
    # SCENE 2: Reactive Forms & Native Controls Studio
    # =========================================================================
    app.bindings.bindInputSignal("user-name", app.userNameSig)
    app.bindings.bindInputSignal("user-role", app.userRoleSig)
    app.bindings.bindInputSignal("tag-query", app.tagQuerySig)
    app.bindings.bindTextSignal("profile-summary", app.profileSummarySig)

    app.bindings.onInput("sync-name", proc(t: string) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.userName = t
        app.profileSummarySig.set(app.updateProfileSummaryText())
    )
    app.bindings.onInput("sync-role", proc(t: string) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.userRole = t
        app.profileSummarySig.set(app.updateProfileSummaryText())
    )
    app.bindings.onInput("sync-tags", proc(t: string) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.tagQuery = t
        app.profileSummarySig.set(app.updateProfileSummaryText())
    )
    app.bindings.onClick("apply-preset", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.userName = "Elena Kovalenko"
        app.userRole = "Principal Kernel Engineer"
        app.tagQuery = "rust-safety, zig-explicit, nim-orc"
        app.userNameSig.set(app.userName)
        app.userRoleSig.set(app.userRole)
        app.tagQuerySig.set(app.tagQuery)
        app.profileSummarySig.set(app.updateProfileSummaryText())
        app.globalStatusSig.set("Preset profile loaded into HTML <input> signals")
    )

    let splitRow = HStack(app.tree, bodyHost, gap = 12.0f, width = flexGrow(), height = flexGrow())

    # Left half: HTML5/CSS3 Reactive Form Card
    let leftCardHost = Box(app.tree, splitRow, direction = fdColumn, width = flexGrow(1.0f), height = flexGrow())
    app.tree.nodes[leftCardHost].alignItems = aiStretch
    let formHtml = """
      <style>
        .form-card {
          flex: 1;
          width: 100%;
          background-color: #121216;
          border: 1px solid #24242C;
          border-radius: 8px;
          padding: 16px;
          gap: 10px;
        }
        .form-title { color: #F8FAFC; font-size: 16px; }
        .field-lbl { color: #94A3B8; font-size: 12px; }
        .form-input {
          width: 100%;
          background-color: #0B0B0F;
          border: 1px solid #2E2E3A;
          border-radius: 6px;
          padding: 8px 10px;
          color: #F8FAFC;
          font-size: 13px;
          height: 34px;
        }
        .summary-box {
          background-color: #161622;
          border: 1px solid #3B3B58;
          border-radius: 6px;
          padding: 10px;
          gap: 4px;
        }
        .summary-txt { color: #93C5FD; font-size: 12px; }
        .preset-btn {
          background-color: #2563EB;
          border: 1px solid #3B82F6;
          border-radius: 6px;
          padding: 7px 14px;
          color: #FFFFFF;
          font-size: 13px;
          height: 34px;
        }
      </style>
      <div class="form-card">
        <h3 class="form-title">HTML5 Two-Way Form Bindings (Zero-JS)</h3>
        <span class="field-lbl">Engineer Full Name (data-bind="user-name")</span>
        <input id="profile-name" class="form-input" data-bind="user-name" data-input="sync-name" placeholder="Enter name..." />
        <span class="field-lbl">Architecture Role (data-bind="user-role")</span>
        <input id="profile-role" class="form-input" data-bind="user-role" data-input="sync-role" placeholder="Enter role..." />
        <span class="field-lbl">Capability Tags (data-bind="tag-query")</span>
        <input id="filter-tag" class="form-input" data-bind="tag-query" data-input="sync-tags" placeholder="Tags..." />
        <div class="summary-box">
          <span class="field-lbl">Live Reactive Summary (Signal&lt;string&gt; DAG)</span>
          <span id="profile-summary" class="summary-txt" data-text="profile-summary">...</span>
        </div>
        <button id="btn-preset" class="preset-btn" data-click="apply-preset">Load Verified Engineer Preset</button>
      </div>
    """
    discard mountHtmlString(app.tree, addr app.rt, formHtml, "", app.bindings, leftCardHost)

    # Right half: Native NimUI Interactive Controls + Multiline TextArea
    let rightCard = VStack(
      app.tree, splitRow,
      padding = 14.0f,
      gap = 10.0f,
      bg = ColBgSurface,
      borderColor = ColBorder,
      radius = 8.0f,
      borderWidth = 1.0f,
      width = flexGrow(1.0f),
      height = flexGrow()
    )
    discard Text(app.tree, rightCard, "Native NimUI Controls & Multiline Config", size = 16.0f, color = ColTextPrim)

    let cbAutoSave = newCheckbox("Auto-save snapshot on commit", checked = app.autoSave, onToggle = proc(c: bool) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.autoSave = c
        app.profileSummarySig.set(app.updateProfileSummaryText())
    )
    let cbAutoId = Checkbox(app.tree, rightCard, cbAutoSave)
    Tooltip(app.tree, cbAutoId, "Synchronizes directly to Profile Summary signal", tpAbove)

    discard Checkbox(app.tree, rightCard, "Enable real-time ORC allocation telemetry", checked = app.enableTelemetry, onToggle = proc(c: bool) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.enableTelemetry = c
    )
    discard Checkbox(app.tree, rightCard, "Notify desktop webhook on threshold breach", checked = app.enableNotify, onToggle = proc(c: bool) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.enableNotify = c
    )

    discard Text(app.tree, rightCard, "Deployment Target (RadioGroup)", size = 12.0f, color = ColTextSec)
    discard RadioGroup(app.tree, rightCard, deployEnvNames(), selectedIndex = app.deployEnvIdx, direction = fdRow, gap = 14.0f, onSelect = proc(idx: int, val: string) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.deployEnvIdx = idx
        app.profileSummarySig.set(app.updateProfileSummaryText())
    )

    let sliderLblSig = app.rt.createSignal(&"Worker Threads: {int(app.workerThreads)}  |  Memory Budget: {int(app.memBudgetMb)} MB")
    let sliderLblId = Text(app.tree, rightCard, sliderLblSig.get(), size = 12.0f, color = ColTextSec)
    bindText(addr app.tree, addr app.rt, sliderLblId, proc(): string {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        sliderLblSig.get()
    )
    discard Slider(app.tree, rightCard, minVal = 1.0f, maxVal = 64.0f, currentVal = app.workerThreads, step = 1.0f, width = flexGrow(), onValueChange = proc(v: float32) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.workerThreads = v
        sliderLblSig.set(&"Worker Threads: {int(app.workerThreads)}  |  Memory Budget: {int(app.memBudgetMb)} MB")
        app.profileSummarySig.set(app.updateProfileSummaryText())
    )
    discard Slider(app.tree, rightCard, minVal = 64.0f, maxVal = 2048.0f, currentVal = app.memBudgetMb, step = 64.0f, width = flexGrow(), onValueChange = proc(v: float32) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.memBudgetMb = v
        sliderLblSig.set(&"Worker Threads: {int(app.workerThreads)}  |  Memory Budget: {int(app.memBudgetMb)} MB")
        app.profileSummarySig.set(app.updateProfileSummaryText())
    )

    let ddId = Dropdown(app.tree, rightCard, items = regionNames(), selectedIndex = app.regionIdx, width = fixed(320.0f), height = fixed(32.0f), onSelect = proc(idx: int) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.regionIdx = idx
        app.profileSummarySig.set(app.updateProfileSummaryText())
    )
    Tooltip(app.tree, ddId, "Select target deployment cluster region", tpBelow)

    discard Text(app.tree, rightCard, "Deployment Manifest Notes (TextArea)", size = 12.0f, color = ColTextSec)
    app.notesHostBox = Box(app.tree, rightCard, width = flexGrow(), height = flexGrow(), bg = 0x0B0B0FFF'u32, borderColor = ColBorder, radius = 6.0f, borderWidth = 1.0f)

  of 2:
    # =========================================================================
    # SCENE 3: Zero-JS Security Sandbox & Live DOM Inspector
    # =========================================================================
    for idx in 0 ..< 4:
      app.bindings.onClick("sandbox-" & $idx, makeSandboxClickProc(app, idx))

    app.bindings.bindTextSignal("sb-verdict", app.sandboxVerdictSig)
    app.bindings.bindTextSignal("sb-stats", app.sandboxStatsSig)
    app.bindings.bindTextSignal("sb-detail", app.sandboxDetailSig)

    let verdictBg = if app.sandboxAllowed: "#112821" else: "#2B1218"
    let verdictBorder = if app.sandboxAllowed: "#10B981" else: "#F43F5E"
    let verdictColor = if app.sandboxAllowed: "#34D399" else: "#FB7185"

    let sbHtml = """
      <style>
        .sb-wrap { display: flex; flex-direction: column; gap: 12px; width: 100%; }
        .sb-bar {
          display: flex;
          flex-direction: row;
          gap: 10px;
          padding: 12px;
          background-color: #121216;
          border: 1px solid #24242C;
          border-radius: 8px;
          align-items: center;
        }
        .sb-btn {
          background-color: #1E293B;
          border: 1px solid #334155;
          border-radius: 6px;
          padding: 6px 12px;
          color: #F8FAFC;
          font-size: 13px;
          height: 32px;
        }
        .sb-btn.safe { background-color: #065F46; border-color: #10B981; }
        .sb-btn.warn { background-color: #4C1D24; border-color: #F43F5E; }
        .sb-verdict {
          background-color: """ & verdictBg & """;
          border: 1px solid """ & verdictBorder & """;
          border-radius: 8px;
          padding: 14px;
          gap: 6px;
        }
        .sb-title { color: """ & verdictColor & """; font-size: 16px; }
        .sb-sub { color: #E2E8F0; font-size: 13px; }
        .sb-err { color: #94A3B8; font-size: 12px; }
      </style>
      <div class="sb-wrap">
        <div class="sb-bar">
          <button id="sb-case-0" class="sb-btn safe" data-click="sandbox-0">Test Valid HTML+CSS Card</button>
          <button id="sb-case-1" class="sb-btn warn" data-click="sandbox-1">Inject &lt;script&gt; Tag</button>
          <button id="sb-case-2" class="sb-btn warn" data-click="sandbox-2">Inject onclick="..."</button>
          <button id="sb-case-3" class="sb-btn warn" data-click="sandbox-3">Inject javascript: URI</button>
        </div>
        <div id="sb-verdict-card" class="sb-verdict">
          <span class="sb-title" data-text="sb-verdict">...</span>
          <span class="sb-sub" data-text="sb-stats">...</span>
          <span class="sb-err" data-text="sb-detail">...</span>
        </div>
      </div>
    """
    discard mountHtmlString(app.tree, addr app.rt, sbHtml, "", app.bindings, bodyHost)

    let previewPanel = VStack(
      app.tree, bodyHost,
      padding = 14.0f,
      gap = 10.0f,
      bg = ColBgSurface,
      borderColor = ColBorder,
      radius = 8.0f,
      borderWidth = 1.0f,
      width = flexGrow(),
      height = flexGrow()
    )
    app.sandboxPreviewBox = previewPanel
    discard Text(app.tree, previewPanel, "Live Mounted DOM Preview (Only populated when Zero-JS validation succeeds):", size = 13.0f, color = ColTextSec)
    if app.sandboxAllowed and app.sandboxMountedHtml.len > 0:
      discard mountHtmlString(app.tree, addr app.rt, app.sandboxMountedHtml, "", app.bindings, previewPanel)
    else:
      discard Box(
        app.tree, previewPanel,
        padding = 14.0f,
        bg = 0x1A1014FF'u32,
        borderColor = 0xF43F5EFF'u32,
        radius = 6.0f,
        borderWidth = 1.0f,
        width = flexGrow()
      )
      discard Text(app.tree, previewPanel, "Preview Blocked: Parser returned Result.err() before creating any UI node.", size = 14.0f, color = 0xFB7185FF'u32)

  else:
    # =========================================================================
    # SCENE 4: 1,000,000-Row Virtual Data Explorer
    # =========================================================================
    app.bindings.bindInputSignal("grid-query", app.gridQuerySig)
    app.bindings.bindTextSignal("grid-status", app.gridStatusSig)
    app.bindings.onInput("grid-filter-input", proc(t: string) {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.gridQuery = t
        app.applyVirtualFilter()
    )
    app.bindings.onClick("mode-all", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.gridFilterMode = 0
        app.applyVirtualFilter()
    )
    app.bindings.onClick("mode-err", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.gridFilterMode = 1
        app.applyVirtualFilter()
    )
    app.bindings.onClick("mode-gpu", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        app.gridFilterMode = 2
        app.applyVirtualFilter()
    )
    app.bindings.onClick("jump-500k", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        let targetRow = min(500_000, max(0, app.virtualCount - 1))
        app.selectedRowIdx = targetRow
        if app.virtualListId != SlabId(-1) and app.tree.nodes.contains(app.virtualListId):
          let vNode = addr app.tree.nodes[app.virtualListId]
          vNode.selectedIndex = targetRow
          vNode.scrollOffset = float32(targetRow) * vNode.itemHeight
          app.tree.isDirty = true
        app.applyVirtualFilter(rebuildList = false)
    )

    let gridTopHtml = """
      <style>
        .grid-hdr {
          display: flex;
          flex-direction: row;
          gap: 10px;
          padding: 12px;
          background-color: #121216;
          border: 1px solid #24242C;
          border-radius: 8px;
          align-items: center;
        }
        .grid-in {
          flex: 1;
          background-color: #0B0B0F;
          border: 1px solid #2E2E3A;
          border-radius: 6px;
          padding: 7px 10px;
          color: #F8FAFC;
          font-size: 13px;
          height: 32px;
        }
        .g-btn {
          background-color: #1E293B;
          border: 1px solid #334155;
          border-radius: 6px;
          padding: 6px 12px;
          color: #E2E8F0;
          font-size: 12px;
          height: 32px;
        }
        .g-btn:hover { background-color: #334155; }
        .g-stat { color: #38BDF8; font-size: 12px; }
      </style>
      <div class="grid-hdr">
        <input id="grid-search" class="grid-in" data-bind="grid-query" data-input="grid-filter-input" placeholder="Search 1,000,000 telemetry records..." />
        <button id="g-all" class="g-btn" data-click="mode-all">All 1M Rows</button>
        <button id="g-err" class="g-btn" data-click="mode-err">Errors Only</button>
        <button id="g-gpu" class="g-btn" data-click="mode-gpu">GPU Nodes</button>
        <button id="g-500k" class="g-btn" data-click="jump-500k">Jump #500,000</button>
        <span id="grid-status" class="g-stat" data-text="grid-status">Ready</span>
      </div>
    """
    discard mountHtmlString(app.tree, addr app.rt, gridTopHtml, "", app.bindings, bodyHost)

    let vList = VirtualList(
      app.tree, bodyHost,
      count = app.virtualCount,
      itemHeight = 28.0f,
      width = flexGrow(),
      height = flexGrow(),
      bg = 0x101014FF'u32,
      renderItem = proc(idx: int, isSelected: bool): string {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          let statusTag = case app.gridFilterMode
            of 1: "ERR_TIMEOUT"
            of 2: "GPU_VULKAN"
            else: (if (idx mod 7 == 0): "WARN" else: "OK")
          let qNote = if app.gridQuery.len > 0: " [" & app.gridQuery & "]" else: ""
          &"[#{idx:07d}] node-{(idx mod 64):02d}  |  {statusTag}  |  {float(idx mod 97) * 0.13 + 0.12:.2f} ms{qNote}",
      onSelect = proc(idx: int) {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          app.selectedRowIdx = idx
          app.applyVirtualFilter(rebuildList = false)
    )
    app.virtualListId = vList
    app.tree.nodes[vList].selectedIndex = app.selectedRowIdx
    app.applyVirtualFilter(rebuildList = false)

  # Run initial layout and reactive flush
  app.tree.layoutTree(float32(StudioWidth), float32(StudioHeight), app.fontAtlas)
  if app.notesHostBox != SlabId(-1) and app.tree.nodes.contains(app.notesHostBox):
    app.configNotesArea.syncWithNode(app.tree, app.notesHostBox, app.fontAtlas)

proc renderFrameToInstances(app: StudioApp, w, h: float32) {.raises: [].} =
  if app.tree.isLayoutDirty:
    app.tree.layoutTree(w, h, app.fontAtlas)
    if app.notesHostBox != SlabId(-1) and app.tree.nodes.contains(app.notesHostBox):
      app.configNotesArea.syncWithNode(app.tree, app.notesHostBox, app.fontAtlas)

  discard app.tree.buildDrawInstances(app.fontAtlas)
  if app.notesHostBox != SlabId(-1) and app.tree.nodes.contains(app.notesHostBox):
    let r = app.tree.nodes[app.notesHostBox].computedRect
    let clip: array[4, uint16] = [
      uint16(max(0.0f, r.x)),
      uint16(max(0.0f, r.y)),
      uint16(min(w, r.x + r.w)),
      uint16(min(h, r.y + r.h))
    ]
    app.configNotesArea.emitDrawInstances(app.tree.drawInstances, app.fontAtlas, clip)
  renderControlOverlays(app.tree, app.fontAtlas, w, h)

proc newStudioApp(alloc: Allocator, atlas: FontAtlas): StudioApp =
  result = StudioApp(
    alloc: alloc,
    fontAtlas: atlas,
    tree: initUiTree(alloc),
    rt: initReactiveRuntime(alloc),
    bindings: initHtmlBindingRegistry(),
    activeTab: 0,
    pendingTab: 0,
    needsRebuild: false,
    rpsVal: 128_450,
    p99Ms: 0.42f,
    activeSignals: 18,
    accentIdx: 0,
    userName: "Alice Vance",
    userRole: "Systems Architect",
    tagQuery: "corex, vulkan, zero-js",
    autoSave: true,
    enableTelemetry: true,
    enableNotify: false,
    deployEnvIdx: 0,
    workerThreads: 16.0f,
    memBudgetMb: 256.0f,
    regionIdx: 0,
    configNotesArea: initTextArea(
      text = "# Deployment Configuration\nengine = \"nimui-html5-css3\"\njs_runtime = \"disabled\"\nmemory_model = \"orc\"",
      fontSize = 12.0f,
      bounds = (0.0f, 0.0f, 320.0f, 140.0f)
    ),
    notesHostBox: SlabId(-1),
    sandboxSampleIdx: 0,
    sandboxAllowed: true,
    sandboxVerdict: "ALLOWED — Pure-Nim Zero-JS DOM Verified",
    sandboxStats: "HTML Nodes: 8 | CSS Rules: 3 | JS Threats: 0",
    sandboxDetail: "Initial sample validated cleanly.",
    sandboxMountedHtml: SampleValidHtml,
    sandboxPreviewBox: SlabId(-1),
    sandboxVerdictCard: SlabId(-1),
    gridQuery: "",
    gridFilterMode: 0,
    virtualCount: 1_000_000,
    selectedRowIdx: 0,
    virtualListId: SlabId(-1)
  )
  result.evalSandboxCase(0)
  result.rebuildScene()

proc destroyStudioApp(app: StudioApp) =
  resetControls()
  app.bindings.destroy()
  app.tree.destroy()
  app.rt.destroy()

proc triggerHtmlButtonById(app: StudioApp, id: string) =
  let nodeOpt = app.bindings.getNodeById(id)
  doAssert nodeOpt.isSome(), "Missing HTML element id: " & id
  let nodeId = nodeOpt.get()
  doAssert app.tree.nodes.contains(nodeId)
  doAssert app.tree.nodes[nodeId].onClick != nil, "Expected onClick handler on #" & id
  app.tree.nodes[nodeId].onClick()
  if app.needsRebuild:
    app.activeTab = app.pendingTab
    app.needsRebuild = false
    app.rebuildScene()

proc runHeadlessVerification(exportDir: string) =
  echo "================================================================="
  echo ">>> HTML5/CSS3 STUDIO HEADLESS VERIFICATION & PNG EXPORT <<<"
  echo "================================================================="
  let atlas = initFontAtlas("Segoe UI", 32.0f)
  if exportDir.len > 0 and not dirExists(exportDir):
    createDir(exportDir)

  testWithLeakCheck("Studio 4-Tab Interactive Scenes & Zero-Leak Audit"):
    let app = newStudioApp(testAlloc, atlas)
    defer: app.destroyStudioApp()

    # Tab 0: Telemetry Dashboard interaction + export
    app.triggerHtmlButtonById("btn-spike")
    doAssert app.rpsVal == 152_950
    let kpiId = app.bindings.getNodeById("kpi-rps").get()
    doAssert app.tree.nodes[kpiId].text == "152,950 req/s"
    app.triggerHtmlButtonById("btn-audit")
    app.renderFrameToInstances(float32(StudioWidth), float32(StudioHeight))
    if exportDir.len > 0:
      var fb0 = initSoftwareFramebuffer(StudioWidth, StudioHeight, ColBgPage)
      fb0.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgPage)
      doAssert fb0.savePng(exportDir / "studio_tab1_dashboard.png")

    # Tab 1: Reactive Forms & Native Controls + export
    app.triggerHtmlButtonById("btn-tab-1")
    doAssert app.activeTab == 1
    let nameInId = app.bindings.getNodeById("profile-name").get()
    doAssert app.tree.nodes[nameInId].onInput != nil
    app.tree.nodes[nameInId].onInput("Ivan Petrov")
    doAssert app.userName == "Ivan Petrov"
    app.triggerHtmlButtonById("btn-preset")
    doAssert app.userName == "Elena Kovalenko"
    app.renderFrameToInstances(float32(StudioWidth), float32(StudioHeight))
    if exportDir.len > 0:
      var fb1 = initSoftwareFramebuffer(StudioWidth, StudioHeight, ColBgPage)
      fb1.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgPage)
      doAssert fb1.savePng(exportDir / "studio_tab2_forms_controls.png")

    # Tab 2: Zero-JS Security Sandbox + export (test rejection then valid)
    app.triggerHtmlButtonById("btn-tab-2")
    doAssert app.activeTab == 2
    app.triggerHtmlButtonById("sb-case-1")
    doAssert not app.sandboxAllowed, "Script injection MUST be rejected"
    app.triggerHtmlButtonById("sb-case-2")
    doAssert not app.sandboxAllowed, "Inline onclick= MUST be rejected"
    app.triggerHtmlButtonById("sb-case-3")
    doAssert not app.sandboxAllowed, "javascript: URI MUST be rejected"
    app.triggerHtmlButtonById("sb-case-0")
    doAssert app.sandboxAllowed, "Valid HTML/CSS card MUST succeed"
    app.triggerHtmlButtonById("sb-case-1")
    doAssert not app.sandboxAllowed
    app.renderFrameToInstances(float32(StudioWidth), float32(StudioHeight))
    if exportDir.len > 0:
      var fb2 = initSoftwareFramebuffer(StudioWidth, StudioHeight, ColBgPage)
      fb2.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgPage)
      doAssert fb2.savePng(exportDir / "studio_tab3_zero_js_sandbox.png")

    # Tab 3: 1M Virtual Explorer + export
    app.triggerHtmlButtonById("btn-tab-3")
    doAssert app.activeTab == 3
    doAssert app.virtualCount == 1_000_000
    app.triggerHtmlButtonById("g-500k")
    doAssert app.selectedRowIdx == 500_000
    app.renderFrameToInstances(float32(StudioWidth), float32(StudioHeight))
    if exportDir.len > 0:
      var fb3 = initSoftwareFramebuffer(StudioWidth, StudioHeight, ColBgPage)
      fb3.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgPage)
      doAssert fb3.savePng(exportDir / "studio_tab4_virtual_million.png")

  echo "  [PASS] HTML5/CSS3 Studio headless interactions & 0-leak audit verified."

proc runInteractiveWindow() =
  var win = initNativeWindow("NimUI HTML5/CSS3 Zero-JS Studio", StudioWidth, StudioHeight)
  let atlas = initFontAtlas("Segoe UI", 32.0f)
  var backendRes = initVulkanBackend(win.hwnd, uint32(win.width), uint32(win.height), atlas)
  if not backendRes.isOk:
    echo "[FATAL] Vulkan init failed: ", backendRes.error
    return
  var backend = backendRes.get()
  let app = newStudioApp(heapAllocator(), atlas)
  var mouseX = 0.0f
  var mouseY = 0.0f

  while win.running:
    let events = win.pollEvents()
    for ev in events:
      case ev.kind
      of ueResize:
        backend.needsResize = true
        app.tree.isLayoutDirty = true
        app.tree.isDirty = true
      of ueMouseMove:
        mouseX = float32(ev.mouseX)
        mouseY = float32(ev.mouseY)
        discard handleControlMouseMove(app.tree, mouseX, mouseY)
        if app.notesHostBox != SlabId(-1) and app.configNotesArea.isDragging:
          app.configNotesArea.handleMouseMove(mouseX, mouseY, atlas)
        app.tree.handleMouseMove(mouseX, mouseY)
      of ueMouseDown:
        mouseX = float32(ev.mouseX)
        mouseY = float32(ev.mouseY)
        var handled = handleControlMouseDown(app.tree, mouseX, mouseY)
        if not handled and app.notesHostBox != SlabId(-1) and app.tree.nodes.contains(app.notesHostBox):
          let b = app.configNotesArea.bounds
          if mouseX >= b.x and mouseX <= b.x + b.w and mouseY >= b.y and mouseY <= b.y + b.h:
            app.configNotesArea.handleMouseDown(mouseX, mouseY, atlas)
            app.configNotesArea.isFocused = true
            handled = true
          else:
            app.configNotesArea.isFocused = false
        if not handled:
          app.tree.handleMouseDown(mouseX, mouseY)
      of ueMouseUp:
        mouseX = float32(ev.mouseX)
        mouseY = float32(ev.mouseY)
        discard handleControlMouseUp(app.tree, mouseX, mouseY)
        if app.notesHostBox != SlabId(-1) and app.configNotesArea.isDragging:
          app.configNotesArea.handleMouseUp(mouseX, mouseY)
        app.tree.handleMouseUp(mouseX, mouseY)
      of ueMouseWheel:
        if app.notesHostBox != SlabId(-1) and app.tree.nodes.contains(app.notesHostBox):
          let b = app.configNotesArea.bounds
          if mouseX >= b.x and mouseX <= b.x + b.w and mouseY >= b.y and mouseY <= b.y + b.h:
            app.configNotesArea.scrollOffsetY = max(0.0f, app.configNotesArea.scrollOffsetY - float32(ev.wheelDelta) * 20.0f)
            continue
        app.tree.handleMouseWheel(mouseX, mouseY, float32(ev.wheelDelta) * 60.0f)
      of ueKeyDown:
        var handled = handleControlKeyDown(app.tree, ev.keyCode)
        if not handled and app.notesHostBox != SlabId(-1) and app.configNotesArea.isFocused:
          discard app.configNotesArea.handleKeyDown(ev.keyCode, ev.ctrlDown, ev.shiftDown)
          handled = true
        if not handled:
          app.tree.handleKeyDown(ev.keyCode, ev.ctrlDown, ev.shiftDown)
      of ueChar:
        if app.notesHostBox != SlabId(-1) and app.configNotesArea.isFocused:
          app.configNotesArea.handleChar(ev.charVal)
        else:
          app.tree.handleChar(ev.charVal)
      else:
        discard

    if app.needsRebuild:
      app.activeTab = app.pendingTab
      app.needsRebuild = false
      app.rebuildScene()
      app.tree.layoutTree(float32(win.width), float32(win.height), atlas)

    if app.tree.isLayoutDirty or backend.needsResize:
      app.tree.layoutTree(float32(win.width), float32(win.height), atlas)
      if app.notesHostBox != SlabId(-1) and app.tree.nodes.contains(app.notesHostBox):
        app.configNotesArea.syncWithNode(app.tree, app.notesHostBox, atlas)

    let frameRes = backend.beginFrame(uint32(win.width), uint32(win.height))
    if frameRes.isOk:
      let imgIdx = frameRes.get()
      app.renderFrameToInstances(float32(win.width), float32(win.height))
      if app.tree.drawInstances.len > 0:
        backend.renderInstances(imgIdx, addr app.tree.drawInstances[0], app.tree.drawInstances.len, ColBgPage)
    else:
      app.tree.isDirty = true

    if not app.tree.isDirty and not app.tree.isLayoutDirty and win.running:
      win.waitEvents(16)

  app.destroyStudioApp()
  backend.destroy()

proc main() =
  var headless = false
  var exportDir = ""
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    if args[i] == "--headless-test":
      headless = true
      inc i
    elif args[i] == "--export-screenshots" and i + 1 < args.len:
      exportDir = args[i + 1]
      headless = true
      inc(i, 2)
    else:
      inc i

  if headless:
    runHeadlessVerification(exportDir)
  else:
    runInteractiveWindow()

when isMainModule:
  main()
