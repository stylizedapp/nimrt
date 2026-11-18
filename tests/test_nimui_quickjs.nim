## tests/test_nimui_quickjs.nim — Comprehensive Tests for QuickJS Hybrid Engine & Philosophy Checks
##
## Covers:
## 1. QuickJS C Engine + corex/allocators.Allocator Bridge + TrackingAllocator (0 leaks)
##    + Rust-Safety runtime limits (step budget interrupt on infinite loop, memory limit)
## 2. JS Philosophy Validator:
##    - Rust Safety: forbids `var`, `==`/`!=`, `eval`, `Function`, `with`, `__proto__`
##    - Zig Explicitness: enforces explicit capabilities (`dom`, `timers`, `nim`, `console`)
##    - Python Simplicity: validates ergonomic `ui.*` & `Nim.*` prelude
## 3. Hybrid Nim + QuickJS DOM + Reactive Signal[T] two-way synchronization
## 4. 1-3s Pomodoro Timer (`apps/html_desktop/ui/pomodoro.html`) countdown, pause/reset,
##    PNG export, and 30-cycle zero-leak lifecycle audit.

import std/[os, strutils]
import corex
import corex/signals
import nimui
import nimui/gpu/font_atlas

proc testEngineLimitsAndZeroLeak() =
  echo "\n================================================================="
  echo ">>> [SUITE 1] QUICKJS ENGINE, LIMITS & ALLOCATOR ZERO-LEAK AUDIT <<<"
  echo "================================================================="

  testWithLeakCheck("1.1 QuickJS Basic Eval, GC & 0-Leak TrackingAllocator"):
    var cfg = defaultQuickJsConfig()
    var engRes = initQuickJsEngine(testAlloc, cfg)
    doAssert engRes.isOk(), "Failed to init QuickJS: " & engRes.error()
    var eng = engRes.get()
    defer: eng.destroy()

    doAssert eng.activeMallocBytes() > 0, "Expected QuickJS allocations routed via testAlloc"

    let res = eng.evalValidated("""
      "use strict";
      const nums = [1, 2, 3, 4, 5];
      const total = nums.reduce((acc, x) => acc + x * 2, 0);
      total;
    """)
    doAssert res.isOk(), "Valid JS failed: " & res.error()
    doAssert res.get() == "30", "Expected 30, got " & res.get()
    echo "  [PASS] 1.1 QuickJS eval & TrackingAllocator bridge verified."

  testWithLeakCheck("1.2 Rust-Safety Runtime Limits (Infinite Loop Interrupt & OOM Guard)"):
    var cfg = defaultQuickJsConfig()
    cfg.memLimitBytes = 1024 * 1024 # 1 MB strict cap
    cfg.maxStepsPerCall = 500'u64   # strict step budget
    var engRes = initQuickJsEngine(testAlloc, cfg)
    doAssert engRes.isOk()
    var eng = engRes.get()
    defer: eng.destroy()

    let infRes = eng.evalValidated("""
      "use strict";
      let x = 0;
      while (true) {
        x += 1;
      }
    """)
    doAssert infRes.isErr(), "Infinite loop must be interrupted by step handler"

    let oomRes = eng.evalValidated("""
      "use strict";
      const huge = new Array(2000000).fill(42);
      huge.length;
    """)
    doAssert oomRes.isErr(), "Huge allocation must be blocked by JS_SetMemoryLimit"
    echo "  [PASS] 1.2 QuickJS infinite-loop interrupt & memory limit verified."

proc testPhilosophyValidator() =
  echo "\n================================================================="
  echo ">>> [SUITE 2] JS PHILOSOPHY VALIDATOR (RUST / ZIG / PYTHON) <<<"
  echo "================================================================="

  testWithLeakCheck("2.1 Rust-Safety Static Rejections (var, ==, !=, eval, Function, with, __proto__)"):
    let cfg = defaultJsValidationConfig()
    let badRust = [
      ("var x = 10;", "[JS-R01]"),
      ("const a = 1; if (a == '1') {}", "[JS-R02]"),
      ("const a = 1; if (a != 2) {}", "[JS-R02]"),
      ("const s = `v=${1 == 2}`;", "[JS-R02]"),
      ("eval('1+1');", "[JS-R03]"),
      ("const fn = new Function('return 1');", "[JS-R03]"),
      ("with (obj) { a = 1; }", "[JS-R03]"),
      ("const o = {}; o.__proto__ = null;", "[JS-R03]")
    ]
    for (snippet, codeTag) in badRust:
      let res = validateJsPhilosophy(snippet, cfg)
      doAssert res.isErr(), "Expected Rust-safety rejection for: " & snippet
      doAssert res.error().find(codeTag) >= 0,
        "Expected tag " & codeTag & " in error '" & res.error() & "'"

    # Ensure literals/comments mentioning forbidden tokens are NOT false positives
    let cleanJs = """
      // var x == 1 eval()
      /* var y != 2 */
      const msg = "var x == 1 != 2 eval()";
      const rx = /var==eval/;
      const v = `escaped ${1 === 1}`;
      const item = { var: 42 };
      const sum = item.var + (10 !== 20 ? 1 : 0);
    """
    let okRes = validateJsPhilosophy(cleanJs, cfg)
    doAssert okRes.isOk(), "Valid strict JS rejected falsely: " & okRes.error()
    echo "  [PASS] 2.1 Rust-safety static checks & zero-false-positive lexer verified."

  testWithLeakCheck("2.2 Zig-Explicitness Capability Enforcement"):
    let domOnlyCfg = defaultJsValidationConfig({jcDom})
    let timerDenied = validateJsPhilosophy("setTimeout(() => {}, 100);", domOnlyCfg)
    doAssert timerDenied.isErr() and timerDenied.error().find("[JS-Z01]") >= 0

    let nimDenied = validateJsPhilosophy("Nim.call('ping');", domOnlyCfg)
    doAssert nimDenied.isErr() and nimDenied.error().find("[JS-Z02]") >= 0

    let consoleDenied = validateJsPhilosophy("console.log('hi');", domOnlyCfg)
    doAssert consoleDenied.isErr() and consoleDenied.error().find("[JS-Z04]") >= 0

    let noDomCfg = defaultJsValidationConfig({jcTimers})
    let domDenied = validateJsPhilosophy("ui.text('lbl', 'ok');", noDomCfg)
    doAssert domDenied.isErr() and domDenied.error().find("[JS-Z03]") >= 0

    let parsedCaps = parseScriptCaps("dom, timers, nim")
    doAssert parsedCaps.isOk() and parsedCaps.get() == {jcDom, jcTimers, jcNimBridge}
    let badCap = parseScriptCaps("dom, magic_eval")
    doAssert badCap.isErr()
    echo "  [PASS] 2.2 Zig-explicitness capability checks verified."

proc testHybridNimJsBridge(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 3] HYBRID NIM + QUICKJS DOM & SIGNAL BRIDGE <<<"
  echo "================================================================="

  testWithLeakCheck("3.1 Coexisting Nim Signal + QuickJS UI Logic & Policy Hardening"):
    var tree = initUiTree(testAlloc)
    defer: tree.destroy()
    var rt = initReactiveRuntime(testAlloc)
    defer: rt.destroy()
    var bindings = initHtmlBindingRegistry()
    defer: bindings.destroy()

    let sharedSig = rt.createSignal("Initial-Nim")
    var nimClicks = 0
    var nimCallsFromJs = 0

    bindings.bindTextSignal("nim-lbl", sharedSig)
    bindings.onClick("nim-btn", proc() {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc nimClicks
        sharedSig.set("NimClick#" & $nimClicks)
    )

    var sessRes = initHtmlJsSession(testAlloc, tree, rt, bindings)
    doAssert sessRes.isOk()
    var sess = sessRes.get()
    defer: sess.destroy()

    sess.registerNimFunc("doubleText", proc(a1, a2: string): string {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc nimCallsFromJs
        a1 & ":" & a2
    )

    # Inline onclick and external <script src> must still be strictly rejected!
    let badInline = sess.mountHtmlWithJs("""<button onclick="x()">Bad</button>""")
    doAssert badInline.isErr()
    let badExt = sess.mountHtmlWithJs("""<script src="remote.js"></script>""")
    doAssert badExt.isErr()

    let html = """
      <div style="display: flex; flex-direction: column; padding: 20px; gap: 10px; background: #11131C;">
        <span id="nim-lbl" data-text="nim-lbl">Initial-Nim</span>
        <span id="js-lbl">Initial-JS</span>
        <button id="nim-btn" data-click="nim-btn">Hybrid Button</button>
        <button id="js-btn">JS Only</button>
      </div>
      <script data-caps="dom,timers,nim,console">
        "use strict";
        ui.on("nim-btn", "click", function() {
          const nimVal = Nim.get("nim-lbl");
          const combined = Nim.call("doubleText", nimVal, "JS-Observed");
          ui.text("js-lbl", combined);
          ui.style("js-lbl", "color", "#10B981");
        });
        ui.on("js-btn", "click", function() {
          Nim.set("nim-lbl", "Written-By-JS");
        });
      </script>
    """
    let mountRes = sess.mountHtmlWithJs(html)
    doAssert mountRes.isOk(), "Mount failed: " & mountRes.error()
    tree.layoutTree(800.0f, 600.0f, atlas)

    # Clicking #nim-btn runs BOTH Nim data-click handler AND QuickJS listener!
    let nimBtn = bindings.getNodeById("nim-btn").get()
    tree.nodes[nimBtn].onClick()
    doAssert nimClicks == 1
    doAssert nimCallsFromJs == 1
    doAssert sharedSig.get() == "NimClick#1"
    doAssert sess.getElementText("js-lbl") == "NimClick#1:JS-Observed"

    # Clicking #js-btn updates Nim Signal[string] directly from QuickJS!
    let jsBtn = bindings.getNodeById("js-btn").get()
    tree.nodes[jsBtn].onClick()
    doAssert sharedSig.get() == "Written-By-JS"
    doAssert sess.getElementText("nim-lbl") == "Written-By-JS"
    echo "  [PASS] 3.1 Hybrid Nim + QuickJS bidirectional reactivity verified."

proc testPomodoroEndToEndAndStress(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 4] 1-3s POMODORO TIMER + 30-CYCLE ZERO-LEAK AUDIT <<<"
  echo "================================================================="

  let pomoPath = currentSourcePath().parentDir().parentDir() / "apps" / "html_desktop" / "ui" / "pomodoro.html"
  doAssert fileExists(pomoPath), "Missing pomodoro.html at " & pomoPath
  let rawHtml = readFile(pomoPath)

  testWithLeakCheck("4.1 Pomodoro 3s Countdown, Pause, Reset & 1s Sprint"):
    proc runPomodoroTest(alloc: Allocator, atlas: FontAtlas, htmlSrc: string) =
      var tree = initUiTree(alloc)
      defer: tree.destroy()
      var rt = initReactiveRuntime(alloc)
      defer: rt.destroy()
      var bindings = initHtmlBindingRegistry()
      defer: bindings.destroy()

      let syncSig = rt.createSignal("Nim Bridge: Ready")
      bindings.bindTextSignal("nim-pomo-sync", syncSig)
      var eventsSeen: seq[string] = @[]

      var sessRes = initHtmlJsSession(alloc, tree, rt, bindings)
      doAssert sessRes.isOk()
      var sess = sessRes.get()
      defer: sess.destroy()

      sess.registerNimFunc("onPomodoroEvent", proc(a1, a2: string): string {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          eventsSeen.add(a1 & ":" & a2)
          let msg = "Nim Sync [" & a1 & "]: " & a2
          syncSig.set(msg)
          msg
      )

      let mRes = sess.mountHtmlWithJs(htmlSrc)
      doAssert mRes.isOk(), "Pomodoro mount failed: " & mRes.error()
      tree.layoutTree(1440.0f, 900.0f, atlas)

      doAssert sess.getElementText("pomo-time") == "00:03.0"
      doAssert sess.getElementText("pomo-cycles") == "Циклов: 0"

      # Start 3s timer, step 1000ms -> 00:02.0, pause -> verify paused at 00:02.0
      tree.nodes[bindings.getNodeById("btn-start").get()].onClick()
      for _ in 0 ..< 10:
        doAssert sess.tick(100).isOk()
      doAssert sess.getElementText("pomo-time") == "00:02.0"

      tree.nodes[bindings.getNodeById("btn-pause").get()].onClick()
      doAssert not sess.hasActiveTimers()
      doAssert sess.getElementText("pomo-phase") == "PAUSED"
      # Ticking while paused must not advance time
      for _ in 0 ..< 5:
        doAssert sess.tick(100).isOk()
      doAssert sess.getElementText("pomo-time") == "00:02.0"

      # Resume and finish remaining 2000ms
      tree.nodes[bindings.getNodeById("btn-start").get()].onClick()
      for _ in 0 ..< 20:
        doAssert sess.tick(100).isOk()
      doAssert sess.getElementText("pomo-time") == "00:00.0"
      doAssert sess.getElementText("pomo-cycles") == "Циклов: 1"
      doAssert sess.getElementText("pomo-phase") == "DONE • ПЕРЕРЫВ"
      doAssert not sess.hasActiveTimers()

      # Reset and switch to 2s preset, then complete cycle #2
      tree.nodes[bindings.getNodeById("btn-preset-2s").get()].onClick()
      doAssert sess.getElementText("pomo-time") == "00:02.0"
      tree.nodes[bindings.getNodeById("btn-start").get()].onClick()
      for _ in 0 ..< 20:
        doAssert sess.tick(100).isOk()
      doAssert sess.getElementText("pomo-cycles") == "Циклов: 2"
      doAssert eventsSeen.len >= 4
    runPomodoroTest(testAlloc, atlas, rawHtml)
    echo "  [PASS] 4.1 Pomodoro 3s/2s/pause/reset workflow verified."

  testWithLeakCheck("4.2 30-Cycle QuickJS + HTML Mount/Tick/Destroy Zero-Leak Stress Audit"):
    for iter in 0 ..< 30:
      var tree = initUiTree(testAlloc)
      var rt = initReactiveRuntime(testAlloc)
      var bindings = initHtmlBindingRegistry()
      let syncSig = rt.createSignal("Ready")
      bindings.bindTextSignal("nim-pomo-sync", syncSig)

      var sessRes = initHtmlJsSession(testAlloc, tree, rt, bindings)
      doAssert sessRes.isOk()
      var sess = sessRes.get()
      sess.registerNimFunc("onPomodoroEvent", proc(a1, a2: string): string {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          syncSig.set(a1 & ":" & a2)
          a1
      )
      doAssert sess.mountHtmlWithJs(rawHtml).isOk()
      tree.nodes[bindings.getNodeById("btn-preset-1s").get()].onClick()
      tree.nodes[bindings.getNodeById("btn-start").get()].onClick()
      for _ in 0 ..< 10:
        doAssert sess.tick(100).isOk()
      doAssert sess.getElementText("pomo-cycles") == "Циклов: 1"
      sess.destroy()
      bindings.destroy()
      tree.destroy()
      rt.destroy()
    echo "  [PASS] 4.2 30-cycle QuickJS HTML mount/tick/destroy leaked 0 bytes."

proc testSecurityBypassResourceAndAudit(atlas: FontAtlas) =
  echo "\n================================================================="
  echo ">>> [SUITE 5] QUICKJS BYPASS, CAPABILITIES, EXHAUSTION & AUDIT <<<"
  echo "================================================================="

  testWithLeakCheck("5.1 Static & Runtime Bypass Prevention (eval, Function, import, proto, Proxy, Reflect)"):
    # Opt-in isolation: default parseHtmlDoc rejects <script>
    let optInRes = parseHtmlDoc("<div><script>const x = 1;</script></div>")
    doAssert optInRes.isErr(), "parseHtmlDoc must reject <script> unless allowJs=true"

    # Static checks for dynamic import, Proxy, Reflect, setPrototypeOf, and new capabilities
    let cfg = defaultJsValidationConfig()
    for snippet in [
      ("import('foo.js');", "[JS-R04]"),
      ("import x from 'foo.js';", "[JS-R04]"),
      ("const p = new Proxy({}, {});", "[JS-R03]"),
      ("Reflect.get({}, 'a');", "[JS-R03]"),
      ("Object.setPrototypeOf({}, null);", "[JS-R03]"),
      ("storage.getItem('k');", "[JS-Z06]"),
      ("network.fetch('https://x');", "[JS-Z07]"),
      ("fs.readFile('a.txt');", "[JS-Z08]"),
      ("process.exec('whoami');", "[JS-Z09]")
    ]:
      let r = validateJsPhilosophy(snippet[0], cfg)
      doAssert r.isErr() and r.error().find(snippet[1]) >= 0,
        "Expected " & snippet[1] & " for: " & snippet[0] & ", got: " & (if r.isErr(): r.error() else: "ok")

    # 'all' must NOT silently grant storage/network/fs/process
    let allCaps = parseScriptCaps("all").get()
    doAssert jcStorage notin allCaps and jcNetwork notin allCaps and
             jcFs notin allCaps and jcProcess notin allCaps

    # Runtime bypasses (even if static validator were bypassed via bracket/property indirection)
    var rtCfg = defaultQuickJsConfig()
    rtCfg.memLimitBytes = 1024 * 1024
    rtCfg.maxStepsPerCall = 10_000'u64
    var engRes = initQuickJsEngine(testAlloc, rtCfg)
    doAssert engRes.isOk()
    var eng = engRes.get()
    defer: eng.destroy()

    let evalBypass = eng.evalValidated("globalThis['ev' + 'al']('1+1');")
    doAssert evalBypass.isErr() and evalBypass.error().find("disabled") >= 0

    let fnBypass1 = eng.evalValidated("[].filter['construct' + 'or']('return 1')();")
    doAssert fnBypass1.isErr() and fnBypass1.error().find("disabled") >= 0

    let fnBypass2 = eng.evalValidated("(() => {})['construct' + 'or']('return 1')();")
    doAssert fnBypass2.isErr() and fnBypass2.error().find("disabled") >= 0

    let protoBypass = eng.evalValidated("Object['setProto' + 'typeOf']({}, null);")
    doAssert protoBypass.isErr() and protoBypass.error().find("disabled") >= 0

    let proxyGone = eng.evalValidated("typeof globalThis.Proxy === 'undefined' && typeof globalThis.Reflect === 'undefined';")
    doAssert proxyGone.isOk() and proxyGone.get() == "true"

    # Stack exhaustion check
    let stackRes = eng.evalValidated("const f = () => f(); f();")
    doAssert stackRes.isErr()

    # Audit log must have recorded validation/eval/resource events
    let logs = eng.getAuditLog()
    doAssert logs.len >= 5
    var sawResource = false
    for ev in logs:
      if ev.kind == jaResourceExhausted:
        sawResource = true
    doAssert sawResource, "Expected jaResourceExhausted in QuickJS audit log"
    echo "  [PASS] 5.1 Bypass prevention, capability separation & audit log verified."

  testWithLeakCheck("5.2 HtmlJsSession Fail-Closed Host Capabilities & Audit"):
    var tree = initUiTree(testAlloc)
    var rt = initReactiveRuntime(testAlloc)
    var bindings = initHtmlBindingRegistry()
    var cfg = defaultQuickJsConfig({jcDom, jcStorage, jcNetwork, jcFs, jcProcess})
    var sessRes = initHtmlJsSession(testAlloc, tree, rt, bindings, cfg)
    doAssert sessRes.isOk()
    var sess = sessRes.get()
    defer:
      sess.destroy()
      bindings.destroy()
      tree.destroy()
      rt.destroy()

    for callCode in [
      "storage.getItem('secret');",
      "network.fetch('https://example.com');",
      "fs.readFile('C:/Windows/win.ini');",
      "process.exec('cmd.exe');"
    ]:
      let r = sess.executeScript(callCode, "<cap-test>", "storage,network,fs,process")
      doAssert r.isErr(), "Host capability must fail closed when no backend is attached: " & callCode

    doAssert sess.auditLog().len >= 4
    echo "  [PASS] 5.2 HtmlJsSession fail-closed host capabilities & audit verified."

proc main() =
  echo "================================================================="
  echo ">>> STARTING NIMUI + QUICKJS HYBRID ENGINE TEST SUITE <<<"
  echo "================================================================="
  let atlas = initFontAtlas("Segoe UI", 32.0f)
  testEngineLimitsAndZeroLeak()
  testPhilosophyValidator()
  testHybridNimJsBridge(atlas)
  testPomodoroEndToEndAndStress(atlas)
  testSecurityBypassResourceAndAudit(atlas)
  echo "\n================================================================="
  echo ">>> [SUCCESS] ALL QUICKJS HYBRID & POMODORO TESTS PASSED (0 LEAKS)! <<<"
  echo "================================================================="

when isMainModule:
  main()
