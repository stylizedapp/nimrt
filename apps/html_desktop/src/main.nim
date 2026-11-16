## =============================================================================
## NimUI Native HTML5/CSS3 Desktop Runner (apps/html_desktop)
##
## A Tauri/Electron alternative in Pure Nim (Zero-JS, No WebView2/Chromium):
## - Loads standalone .html files (default: apps/html_desktop/ui/showcase.html
##   or any custom file via --file <path.html>)
## - Parses HTML5 + embedded <style> CSS3, validates Zero-JS security policy
## - Mounts directly onto Retained-Mode Slab[UiNode] + Reactive Signal[T] DAG
## - Renders interactively via Vulkan 1.1+ Instanced SDF (1440x900) or exports
##   deterministic Software SDF PNGs via --headless-test / --screenshot
## =============================================================================

import std/[os, strutils, monotimes, times]
import corex
import corex/unicode
import corex/signals
import nimui
import nimui/controls
import nimui/window
import nimui/gpu/[vulkan_backend, font_atlas]

const
  DesktopWidth  = 1440
  DesktopHeight = 900
  ColBgClear    = 0x090A0FFF'u32

  NavLabels = [
    "Обзор & Формы",
    "CSS3 Каскад",
    "Vulkan SDF",
    "Безопасность"
  ]

type
  HtmlDesktopApp = ref object
    alloc: Allocator
    fontAtlas: FontAtlas
    tree: UiTree
    rt: ReactiveRuntime
    bindings: HtmlBindingRegistry
    jsSession: HtmlJsSession
    allowJs: bool
    nimPingCount: int

    htmlPath: string
    domNodesCount: int
    cssRulesCount: int

    activeNavIdx: int
    loadFactor: int
    inspectClicks: int
    profileName: string
    appName: string
    winTitle: string
    ipcUrl: string

    headerModeSig: Signal[string]
    ramBadgeSig: Signal[string]
    kpiFpsSig: Signal[string]
    kpiMemSig: Signal[string]
    kpiDomSig: Signal[string]
    kpiSecSig: Signal[string]
    liveSummarySig: Signal[string]
    activeProfilePillSig: Signal[string]
    logLatestSig: Signal[string]
    footerStatusSig: Signal[string]

    appNameSig: Signal[string]
    winTitleSig: Signal[string]
    ipcUrlSig: Signal[string]
    nimPomoSyncSig: Signal[string]

proc defaultShowcaseHtmlPath(): string =
  let srcDir = currentSourcePath().parentDir()
  normalizedPath(srcDir.parentDir() / "ui" / "showcase.html")

proc defaultPomodoroHtmlPath(): string =
  let srcDir = currentSourcePath().parentDir()
  normalizedPath(srcDir.parentDir() / "ui" / "pomodoro.html")

proc formatSummary(app: HtmlDesktopApp): string {.raises: [].} =
  app.appName & " • " & app.winTitle & " • " & app.ipcUrl

proc updateNavVisuals(app: HtmlDesktopApp) {.raises: [].} =
  for i in 0 ..< 4:
    let optId = app.bindings.getNodeById("nav-tab-" & $i)
    if optId.isSome():
      let slab = optId.get()
      if app.tree.nodes.contains(slab):
        if i == app.activeNavIdx:
          app.tree.nodes[slab].bgColor = 0x312E81FF'u32
          app.tree.nodes[slab].borderColor = 0x4F46E5FF'u32
          app.tree.nodes[slab].textColor = 0xFFFFFFFF'u32
        else:
          app.tree.nodes[slab].bgColor = 0x191B26FF'u32
          app.tree.nodes[slab].borderColor = 0x2E3248FF'u32
          app.tree.nodes[slab].textColor = 0xCBD5E1FF'u32
  app.tree.isDirty = true

proc syncDerivedSignals(app: HtmlDesktopApp) {.raises: [].} =
  if app.liveSummarySig.runtime != nil:
    app.liveSummarySig.set(app.formatSummary())
  if app.activeProfilePillSig.runtime != nil:
    app.activeProfilePillSig.set("Активный профиль: " & app.profileName & " • Нагрузка " & $app.loadFactor & "x")
  if app.headerModeSig.runtime != nil:
    app.headerModeSig.set("Режим: " & NavLabels[clamp(app.activeNavIdx, 0, 3)])
  if app.kpiFpsSig.runtime != nil:
    let fpsVal = max(240, 1650 - (app.loadFactor - 1) * 140)
    let msVal = 1000.0f / float32(fpsVal)
    let msWhole = int(msVal)
    let msFrac = int((msVal - float32(msWhole)) * 100.0f + 0.5f)
    let msStr = $msWhole & "." & (if msFrac < 10: "0" & $msFrac else: $msFrac)
    app.kpiFpsSig.set($fpsVal & " FPS (" & msStr & " ms)")

proc makeNavClickProc(app: HtmlDesktopApp, idx: int): HtmlClickProc {.raises: [].} =
  result = proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.activeNavIdx = idx
      app.updateNavVisuals()
      app.syncDerivedSignals()
      if app.logLatestSig.runtime != nil:
        app.logLatestSig.set("Переключена вкладка шапки: " & NavLabels[idx] & " (#nav-tab-" & $idx & ")")
      if app.footerStatusSig.runtime != nil:
        app.footerStatusSig.set("Статус: Выбран раздел «" & NavLabels[idx] & "» (Pure-Nim Reactive)")

proc registerShowcaseBindings(app: HtmlDesktopApp) {.raises: [].} =
  for i in 0 ..< 4:
    app.bindings.onClick("nav-" & $i, makeNavClickProc(app, i))

  app.bindings.onClick("inspect-css", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      inc app.inspectClicks
      if app.logLatestSig.runtime != nil:
        app.logLatestSig.set("Проверка события <li> -> <span> # " & $app.inspectClicks & ": propagateOnClick сработал!")
      if app.footerStatusSig.runtime != nil:
        app.footerStatusSig.set("Статус: Подтверждена передача клика по вложенным HTML-элементам (x" & $app.inspectClicks & ")")
  )

  app.bindings.onClick("preset-prod", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.appName = "NimUI Production Core"
      app.winTitle = "Продакшн-кластер • 64B SDF"
      app.ipcUrl = "ipc://prod/corex-slab"
      app.profileName = "Продакшн-сервер"
      app.appNameSig.set(app.appName)
      app.winTitleSig.set(app.winTitle)
      app.ipcUrlSig.set(app.ipcUrl)
      app.syncDerivedSignals()
      if app.logLatestSig.runtime != nil:
        app.logLatestSig.set("Активирован профиль «Продакшн» через data-click=\"preset-prod\"")
      if app.footerStatusSig.runtime != nil:
        app.footerStatusSig.set("Статус: Применён профиль Продакшн (Signal<T> синхронизирован)")
  )

  app.bindings.onClick("preset-edge", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.appName = "Edge AI Vision Node"
      app.winTitle = "Встраиваемый Vulkan HUD"
      app.ipcUrl = "ipc://edge/npu-zero-copy"
      app.profileName = "Edge AI Модуль"
      app.loadFactor = 2
      app.appNameSig.set(app.appName)
      app.winTitleSig.set(app.winTitle)
      app.ipcUrlSig.set(app.ipcUrl)
      app.syncDerivedSignals()
      if app.logLatestSig.runtime != nil:
        app.logLatestSig.set("Профиль переключён на Edge AI (data-bind обновил 3 <input> и сводку)")
      if app.footerStatusSig.runtime != nil:
        app.footerStatusSig.set("Статус: Профиль Edge AI активен • Нулевой расход на JS")
  )

  app.bindings.onClick("boost-load", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.loadFactor = (app.loadFactor mod 6) + 1
      app.syncDerivedSignals()
      if app.logLatestSig.runtime != nil:
        app.logLatestSig.set("Симуляция нагрузки " & $app.loadFactor & "x • Перерасчёт FPS без пересборки DOM")
      if app.footerStatusSig.runtime != nil:
        app.footerStatusSig.set("Статус: Нагрузка установлена на " & $app.loadFactor & "x")
  )

  app.bindings.onClick("reset-state", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      app.appName = "NimUI Tauri-Killer"
      app.winTitle = "Vulkan SDF Телеметрия"
      app.ipcUrl = "ipc://corex/zero-alloc"
      app.profileName = "Стандартный кластер"
      app.loadFactor = 1
      app.activeNavIdx = 0
      app.appNameSig.set(app.appName)
      app.winTitleSig.set(app.winTitle)
      app.ipcUrlSig.set(app.ipcUrl)
      app.updateNavVisuals()
      app.syncDerivedSignals()
      if app.logLatestSig.runtime != nil:
        app.logLatestSig.set("Состояние сброшено к исходным значениям showcase.html")
      if app.footerStatusSig.runtime != nil:
        app.footerStatusSig.set("Статус: Ожидание действий (Pure-Nim Zero-JS Reactive Mode)")
  )

  app.bindings.onInput("on-app-name", proc(txt: string) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      var copy = newStringOfCap(txt.len)
      copy.add(txt)
      app.appName = copy
      app.syncDerivedSignals()
  )
  app.bindings.onInput("on-win-title", proc(txt: string) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      var copy = newStringOfCap(txt.len)
      copy.add(txt)
      app.winTitle = copy
      app.syncDerivedSignals()
  )
  app.bindings.onInput("on-ipc-url", proc(txt: string) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      var copy = newStringOfCap(txt.len)
      copy.add(txt)
      app.ipcUrl = copy
      app.syncDerivedSignals()
  )

  app.bindings.bindInputSignal("app-name", app.appNameSig)
  app.bindings.bindInputSignal("win-title", app.winTitleSig)
  app.bindings.bindInputSignal("ipc-url", app.ipcUrlSig)

  app.bindings.bindTextSignal("header-mode", app.headerModeSig)
  app.bindings.bindTextSignal("ram-badge", app.ramBadgeSig)
  app.bindings.bindTextSignal("kpi-fps", app.kpiFpsSig)
  app.bindings.bindTextSignal("kpi-mem", app.kpiMemSig)
  app.bindings.bindTextSignal("kpi-dom", app.kpiDomSig)
  app.bindings.bindTextSignal("kpi-sec", app.kpiSecSig)
  app.bindings.bindTextSignal("live-summary", app.liveSummarySig)
  app.bindings.bindTextSignal("active-profile-pill", app.activeProfilePillSig)
  app.bindings.bindTextSignal("log-latest", app.logLatestSig)
  app.bindings.bindTextSignal("footer-status", app.footerStatusSig)
  app.bindings.bindTextSignal("nim-pomo-sync", app.nimPomoSyncSig)

  app.bindings.onClick("nim-ping", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      inc app.nimPingCount
      if app.nimPomoSyncSig.runtime != nil:
        app.nimPomoSyncSig.set("Nim Ping #" & $app.nimPingCount & " (Pure-Nim Handler)")
  )

proc loadHtmlSource(app: HtmlDesktopApp, rawHtml: string) =
  resetControls()
  app.jsSession.destroy()
  app.bindings.destroy()
  app.tree.destroy()
  app.rt.destroy()

  app.tree = initUiTree(app.alloc)
  app.rt = initReactiveRuntime(app.alloc)
  app.bindings = initHtmlBindingRegistry()

  app.appNameSig = app.rt.createSignal("")
  app.winTitleSig = app.rt.createSignal("")
  app.ipcUrlSig = app.rt.createSignal("")

  app.headerModeSig = app.rt.createSignal("")
  app.ramBadgeSig = app.rt.createSignal("")
  app.kpiFpsSig = app.rt.createSignal("")
  app.kpiMemSig = app.rt.createSignal("")
  app.kpiDomSig = app.rt.createSignal("")
  app.kpiSecSig = app.rt.createSignal("")
  app.liveSummarySig = app.rt.createSignal("")
  app.activeProfilePillSig = app.rt.createSignal("")
  app.logLatestSig = app.rt.createSignal("")
  app.footerStatusSig = app.rt.createSignal("")
  app.nimPomoSyncSig = app.rt.createSignal("Nim Bridge: Ready")

  app.registerShowcaseBindings()

  if app.allowJs:
    let sessRes = initHtmlJsSession(app.alloc, app.tree, app.rt, app.bindings)
    if sessRes.isOk():
      app.jsSession = sessRes.get()
      app.jsSession.registerNimFunc("onPomodoroEvent", proc(a1, a2: string): string {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          let msg = "Nim Sync [" & a1 & "]: " & a2
          if app.nimPomoSyncSig.runtime != nil:
            app.nimPomoSyncSig.set(msg)
          msg
      )
      let mountRes = app.jsSession.mountHtmlWithJs(rawHtml)
      if mountRes.isErr():
        let errMsg = mountRes.error()
        try: echo "[ERROR] JS/HTML Philosophy Rejection: ", errMsg except CatchableError: discard
        let fallbackErrHtml = """
          <div style="display: flex; flex-direction: column; padding: 32px; gap: 14px; background-color: #1A0E12; border: 2px solid #F43F5E; border-radius: 12px; width: 100%; height: 100%;">
            <h1 style="color: #FB7185; font-size: 22px;">QuickJS Philosophy / Policy Rejection</h1>
            <p style="color: #F8FAFC; font-size: 14px;">""" & errMsg & """</p>
          </div>
        """
        # Safe: app.rt is owned by app and outlives the mounted fallback UI tree.
        var fbRes: Result[SlabId, string]
        block trustedUnsafe:
          fbRes = mountHtmlString(app.tree, addr app.rt, fallbackErrHtml, "", app.bindings)
        if fbRes.isErr():
          try: echo "[ERROR] Fallback mount failed: ", fbRes.error() except CatchableError: discard
    else:
      try: echo "[ERROR] Failed to init QuickJS session: ", sessRes.error() except CatchableError: discard
  else:
    let parsed = parseHtmlDoc(rawHtml)
    if parsed.isOk():
      let doc = parsed.get()
      let sheet = parseCssSheet(doc.embeddedCss)
      app.domNodesCount = doc.nodes.len
      app.cssRulesCount = sheet.rules.len

      # Safe: app.rt is owned by app and outlives the mounted UI tree.
      var mountRes: Result[SlabId, string]
      block trustedUnsafe:
        mountRes = mountHtml(app.tree, addr app.rt, doc, sheet, app.bindings)
      if mountRes.isErr():
        try: echo "[ERROR] Failed to mount HTML: ", mountRes.error() except CatchableError: discard
      else:
        # Sync app mirror fields with seeded HTML <input value="..."> signals if present
        if app.appNameSig.get().len > 0:
          app.appName = app.appNameSig.get()
        if app.winTitleSig.get().len > 0:
          app.winTitle = app.winTitleSig.get()
        if app.ipcUrlSig.get().len > 0:
          app.ipcUrl = app.ipcUrlSig.get()
        app.kpiDomSig.set($app.domNodesCount & " узлов • " & $app.cssRulesCount & " правил")
    else:
      let errMsg = parsed.error()
      let fallbackErrHtml = """
        <div style="display: flex; flex-direction: column; padding: 32px; gap: 14px; background-color: #1A0E12; border: 2px solid #F43F5E; border-radius: 12px; width: 100%; height: 100%;">
          <h1 style="color: #FB7185; font-size: 22px;">Zero-JS Policy Rejection — Небезопасный HTML файл отклонён</h1>
          <p style="color: #F8FAFC; font-size: 14px;">""" & errMsg & """</p>
          <p style="color: #94A3B8; font-size: 13px;">Движок NimUI блокирует теги &lt;script&gt;, inline-обработчики on* и javascript: URI на этапе разбора DOM до выделения UI-узлов.</p>
        </div>
      """
      # Safe: app.rt is owned by app and outlives the mounted fallback UI tree.
      var fbRes: Result[SlabId, string]
      block trustedUnsafe:
        fbRes = mountHtmlString(app.tree, addr app.rt, fallbackErrHtml, "", app.bindings)
      if fbRes.isErr():
        try: echo "[ERROR] Fallback mount failed: ", fbRes.error() except CatchableError: discard

  app.tree.layoutTree(float32(DesktopWidth), float32(DesktopHeight), app.fontAtlas)

proc newHtmlDesktopApp(alloc: Allocator, atlas: FontAtlas, htmlPath: string, allowJs: bool = false): HtmlDesktopApp =
  result = HtmlDesktopApp(
    alloc: alloc,
    fontAtlas: atlas,
    tree: initUiTree(alloc),
    rt: initReactiveRuntime(alloc),
    bindings: initHtmlBindingRegistry(),
    allowJs: allowJs,
    nimPingCount: 0,
    htmlPath: htmlPath,
    domNodesCount: 0,
    cssRulesCount: 0,
    activeNavIdx: 0,
    loadFactor: 1,
    inspectClicks: 0,
    profileName: "Стандартный кластер",
    appName: "NimUI Tauri-Killer",
    winTitle: "Vulkan SDF Телеметрия",
    ipcUrl: "ipc://corex/zero-alloc"
  )
  let rawHtml =
    try: readFile(htmlPath)
    except CatchableError: ""
  result.loadHtmlSource(rawHtml)

proc destroyDesktopApp(app: HtmlDesktopApp) =
  resetControls()
  app.jsSession.destroy()
  app.bindings.destroy()
  app.tree.destroy()
  app.rt.destroy()

proc triggerById(app: HtmlDesktopApp, id: string) =
  let nodeOpt = app.bindings.getNodeById(id)
  doAssert nodeOpt.isSome(), "Missing HTML element #" & id
  let nodeId = nodeOpt.get()
  doAssert app.tree.nodes.contains(nodeId)
  doAssert app.tree.nodes[nodeId].onClick != nil, "Missing onClick on #" & id
  app.tree.nodes[nodeId].onClick()

proc runHeadlessVerification(htmlPath, screenshotInitial, screenshotInteractive: string) =
  echo "================================================================="
  echo ">>> HTML5/CSS3 DESKTOP RUNNER HEADLESS VERIFICATION <<<"
  echo "================================================================="
  doAssert fileExists(htmlPath), "HTML file not found: " & htmlPath
  let rawHtml =
    try: readFile(htmlPath)
    except CatchableError: ""
  let atlas = initFontAtlas("Segoe UI", 32.0f)

  testWithLeakCheck("HTML5/CSS3 Showcase Mount, Interactions & Zero-Leak Audit"):
    let app = HtmlDesktopApp(
      alloc: testAlloc,
      fontAtlas: atlas,
      tree: initUiTree(testAlloc),
      rt: initReactiveRuntime(testAlloc),
      bindings: initHtmlBindingRegistry(),
      htmlPath: htmlPath,
      activeNavIdx: 0,
      loadFactor: 1,
      inspectClicks: 0,
      profileName: "Стандартный кластер",
      appName: "NimUI Tauri-Killer",
      winTitle: "Vulkan SDF Телеметрия",
      ipcUrl: "ipc://corex/zero-alloc"
    )
    defer: app.destroyDesktopApp()

    app.loadHtmlSource(rawHtml)
    doAssert app.domNodesCount >= 60, "Expected rich showcase HTML DOM, got " & $app.domNodesCount
    doAssert app.cssRulesCount >= 35, "Expected rich CSS3 ruleset, got " & $app.cssRulesCount

    # Ensure root body expanded cleanly to full viewport
    let rootRect = app.tree.nodes[app.tree.rootId].computedRect
    doAssert rootRect.w >= 1439.0f and rootRect.h >= 899.0f,
      "Expected 1440x900 body stretch, got " & $rootRect.w & "x" & $rootRect.h

    # Export initial PNG screenshot
    discard app.tree.buildDrawInstances(atlas)
    if screenshotInitial.len > 0:
      let pDir = screenshotInitial.parentDir()
      if pDir.len > 0 and not dirExists(pDir):
        try: createDir(pDir) except CatchableError: discard
      var fbInit = initSoftwareFramebuffer(DesktopWidth, DesktopHeight, ColBgClear)
      fbInit.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgClear)
      doAssert fbInit.savePng(screenshotInitial), "Failed saving initial screenshot: " & screenshotInitial

    # Verify nested child click propagation on <li><span>
    let capOpt = app.bindings.getNodeById("cap-0")
    doAssert capOpt.isSome()
    let capId = capOpt.get()
    doAssert app.tree.nodes[capId].children.len > 0
    let capChild = app.tree.nodes[capId].children[0]
    doAssert app.tree.nodes[capChild].onClick != nil, "Expected propagated onClick on nested <span>"
    app.tree.nodes[capChild].onClick()
    doAssert app.inspectClicks == 1

    # Verify nav tab, preset button & two-way <input> signal bindings
    app.triggerById("nav-tab-2")
    doAssert app.activeNavIdx == 2

    app.triggerById("btn-preset-edge")
    doAssert app.appName == "Edge AI Vision Node"
    let nameInputOpt = app.bindings.getNodeById("inp-app-name")
    doAssert nameInputOpt.isSome()
    doAssert app.tree.nodes[nameInputOpt.get()].text == "Edge AI Vision Node"

    app.tree.nodes[nameInputOpt.get()].onInput("NimUI Vulkan Edge")
    doAssert app.appNameSig.get() == "NimUI Vulkan Edge"

    app.triggerById("btn-boost")
    doAssert app.loadFactor == 3

    app.tree.layoutTree(float32(DesktopWidth), float32(DesktopHeight), atlas)
    discard app.tree.buildDrawInstances(atlas)
    if screenshotInteractive.len > 0:
      let pDir = screenshotInteractive.parentDir()
      if pDir.len > 0 and not dirExists(pDir):
        try: createDir(pDir) except CatchableError: discard
      var fbInter = initSoftwareFramebuffer(DesktopWidth, DesktopHeight, ColBgClear)
      fbInter.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgClear)
      doAssert fbInter.savePng(screenshotInteractive), "Failed saving interactive screenshot: " & screenshotInteractive

  echo "  [PASS] HTML5/CSS3 Desktop Runner verified (DOM nodes & 0-leak ORC audit)."

proc runPomodoroVerification(htmlPath, screenshotInitial, screenshotCompleted: string) =
  echo "================================================================="
  echo ">>> POMODORO 1-3s HYBRID NIM + QUICKJS HEADLESS VERIFICATION <<<"
  echo "================================================================="
  doAssert fileExists(htmlPath), "Pomodoro HTML not found: " & htmlPath
  let rawHtml =
    try: readFile(htmlPath)
    except CatchableError: ""
  let atlas = initFontAtlas("Segoe UI", 32.0f)

  testWithLeakCheck("Pomodoro 1-3s Hybrid Nim + QuickJS Timer & Zero-Leak Audit"):
    let app = HtmlDesktopApp(
      alloc: testAlloc,
      fontAtlas: atlas,
      tree: initUiTree(testAlloc),
      rt: initReactiveRuntime(testAlloc),
      bindings: initHtmlBindingRegistry(),
      allowJs: true,
      nimPingCount: 0,
      htmlPath: htmlPath,
      activeNavIdx: 0,
      loadFactor: 1,
      inspectClicks: 0,
      profileName: "Pomodoro",
      appName: "NimUI Pomodoro",
      winTitle: "Pomodoro Debug",
      ipcUrl: "ipc://nimui/pomodoro"
    )
    defer: app.destroyDesktopApp()

    app.loadHtmlSource(rawHtml)
    doAssert app.jsSession.getElementText("pomo-time") == "00:03.0",
      "Expected initial 00:03.0, got " & app.jsSession.getElementText("pomo-time")

    discard app.tree.buildDrawInstances(atlas)
    if screenshotInitial.len > 0:
      let pDir = screenshotInitial.parentDir()
      if pDir.len > 0 and not dirExists(pDir):
        try: createDir(pDir) except CatchableError: discard
      var fbInit = initSoftwareFramebuffer(DesktopWidth, DesktopHeight, ColBgClear)
      fbInit.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgClear)
      doAssert fbInit.savePng(screenshotInitial), "Failed saving initial pomodoro screenshot"

    # Switch to 1.0s debug preset and start
    app.triggerById("btn-preset-1s")
    doAssert app.jsSession.getElementText("pomo-time") == "00:01.0"
    app.triggerById("btn-start")
    doAssert app.jsSession.hasActiveTimers()

    for step in 0 ..< 10:
      let tickRes = app.jsSession.tick(100)
      doAssert tickRes.isOk(), "QuickJS timer tick failed: " & tickRes.error()

    doAssert app.jsSession.getElementText("pomo-time") == "00:00.0"
    doAssert app.jsSession.getElementText("pomo-cycles") == "Циклов: 1"
    doAssert app.jsSession.getElementText("pomo-phase") == "DONE • ПЕРЕРЫВ"
    doAssert app.nimPomoSyncSig.get() == "Nim Sync [completed]: cycle=1",
      "Unexpected Nim sync signal: " & app.nimPomoSyncSig.get()

    # Also trigger Pure-Nim handler button on the same page
    app.triggerById("btn-nim-ping")
    doAssert app.nimPingCount == 1
    doAssert app.nimPomoSyncSig.get() == "Nim Ping #1 (Pure-Nim Handler)"

    app.tree.layoutTree(float32(DesktopWidth), float32(DesktopHeight), atlas)
    discard app.tree.buildDrawInstances(atlas)
    if screenshotCompleted.len > 0:
      let pDir = screenshotCompleted.parentDir()
      if pDir.len > 0 and not dirExists(pDir):
        try: createDir(pDir) except CatchableError: discard
      var fbDone = initSoftwareFramebuffer(DesktopWidth, DesktopHeight, ColBgClear)
      fbDone.renderInstancesToBuffer(app.tree.drawInstances, atlas, clearColor = ColBgClear)
      doAssert fbDone.savePng(screenshotCompleted), "Failed saving completed pomodoro screenshot"

  echo "  [PASS] Pomodoro 1-3s Hybrid Nim + QuickJS verified (0 leaks)."

proc runInteractiveWindow(htmlPath: string, allowJs: bool) =
  if not fileExists(htmlPath):
    echo "[FATAL] HTML file does not exist: ", htmlPath
    return

  var win = initNativeWindow("NimUI HTML5/CSS3 Desktop — " & extractFilename(htmlPath), DesktopWidth, DesktopHeight)
  let atlas = initFontAtlas("Segoe UI", 32.0f)
  var backendRes = initVulkanBackend(win.hwnd, uint32(win.width), uint32(win.height), atlas)
  if not backendRes.isOk:
    echo "[FATAL] Vulkan init failed: ", backendRes.error
    return
  var backend = backendRes.get()
  let app = newHtmlDesktopApp(heapAllocator(), atlas, htmlPath, allowJs)
  var mouseX = 0.0f
  var mouseY = 0.0f
  var lastTickTime = getMonoTime()

  while win.running:
    let nowTime = getMonoTime()
    let dtMs = int(inMilliseconds(nowTime - lastTickTime))
    if dtMs > 0:
      lastTickTime = nowTime
      if app.allowJs and app.jsSession.hasActiveTimers():
        let tickRes = app.jsSession.tick(dtMs)
        if tickRes.isErr():
          try: echo "[ERROR] QuickJS timer tick failed: ", tickRes.error() except CatchableError: discard

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
        app.tree.handleMouseMove(mouseX, mouseY)
      of ueMouseDown:
        mouseX = float32(ev.mouseX)
        mouseY = float32(ev.mouseY)
        app.tree.handleMouseDown(mouseX, mouseY)
      of ueMouseUp:
        mouseX = float32(ev.mouseX)
        mouseY = float32(ev.mouseY)
        app.tree.handleMouseUp(mouseX, mouseY)
      of ueMouseWheel:
        app.tree.handleMouseWheel(mouseX, mouseY, float32(ev.wheelDelta) * 56.0f)
      of ueKeyDown:
        app.tree.handleKeyDown(ev.keyCode, ev.ctrlDown, ev.shiftDown)
      of ueChar:
        app.tree.handleChar(ev.charVal)
      else:
        discard

    if app.tree.isLayoutDirty or backend.needsResize:
      app.tree.layoutTree(float32(win.width), float32(win.height), atlas)

    let frameRes = backend.beginFrame(uint32(win.width), uint32(win.height))
    if frameRes.isOk:
      let imgIdx = frameRes.get()
      discard app.tree.buildDrawInstances(atlas)
      if app.tree.drawInstances.len > 0:
        # Safe: drawInstances.len > 0 is checked; pointer valid for synchronous Vulkan upload.
        block trustedUnsafe:
          backend.renderInstances(imgIdx, addr app.tree.drawInstances[0], app.tree.drawInstances.len, ColBgClear)
    else:
      app.tree.isDirty = true

    if not app.tree.isDirty and not app.tree.isLayoutDirty and win.running:
      if app.allowJs and app.jsSession.hasActiveTimers():
        try: sleep(16) except CatchableError: discard
      else:
        win.waitEvents(16)

  app.destroyDesktopApp()
  backend.destroy()

proc main() =
  var htmlPath = defaultShowcaseHtmlPath()
  var headless = false
  var pomodoroTest = false
  var allowJs = false
  var screenshotInitial = ""
  var screenshotInteractive = ""

  let args =
    try: commandLineParams()
    except CatchableError: @[]
  var i = 0
  while i < args.len:
    if (args[i] == "--file" or args[i] == "--html") and i + 1 < args.len:
      htmlPath = args[i + 1]
      inc(i, 2)
    elif args[i] == "--headless-test":
      headless = true
      inc i
    elif args[i] == "--pomodoro":
      htmlPath = defaultPomodoroHtmlPath()
      allowJs = true
      inc i
    elif args[i] == "--pomodoro-test":
      htmlPath = defaultPomodoroHtmlPath()
      pomodoroTest = true
      allowJs = true
      inc i
    elif args[i] == "--allow-js":
      allowJs = true
      inc i
    elif args[i] == "--screenshot" and i + 1 < args.len:
      screenshotInitial = args[i + 1]
      inc(i, 2)
    elif args[i] == "--screenshot-interactive" and i + 1 < args.len:
      screenshotInteractive = args[i + 1]
      inc(i, 2)
    else:
      inc i

  if htmlPath.endsWith("pomodoro.html"):
    allowJs = true

  if pomodoroTest:
    runPomodoroVerification(htmlPath, screenshotInitial, screenshotInteractive)
  elif headless or screenshotInitial.len > 0 or screenshotInteractive.len > 0:
    runHeadlessVerification(htmlPath, screenshotInitial, screenshotInteractive)
  else:
    runInteractiveWindow(htmlPath, allowJs)

main()
