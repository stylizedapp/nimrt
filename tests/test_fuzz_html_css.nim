## tests/test_fuzz_html_css.nim
##
## Deterministic 100,000-input fuzzer for:
## - Pure-Nim HTML5 Parser (`parseHtmlDoc`, `innerText`, `findById`)
## - CSS3 Parser & Cascade (`parseCssSheet`, `parseCssColor`, `parseCssLength`, `parseCssDeclarations`, `resolveCssVars`, `computeNodeStyle`)
## - QuickJS Philosophy Validator (`validateJsPhilosophy`, `parseScriptCaps`)
##
## Verifies zero crashes, zero hangs, and zero unhandled exceptions across:
## unclosed tags, nested depth bombs, malformed CSS, weird selectors,
## cyclic CSS vars, unicode, empty strings, and embedded null bytes.

import corex
import corex/signals
import nimui/[layout, html_css]
import nimui/js/js_validator

type
  FuzzRng = object
    state: uint64

proc initFuzzRng(seed: uint64): FuzzRng {.inline, raises: [].} =
  FuzzRng(state: seed)

proc nextU64(r: var FuzzRng): uint64 {.inline, raises: [].} =
  var x = r.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  r.state = x
  x

proc nextInt(r: var FuzzRng, bound: int): int {.inline, raises: [].} =
  if bound <= 0:
    return 0
  int(r.nextU64() mod uint64(bound))

const
  HtmlSeeds = [
    "",
    "\0\0\0",
    "<div><span>hello</span>",
    "<!-- unclosed comment",
    "<!DOCTYPE html><html lang='en'><head><style>.a{color:red}</style></head><body><p>A &amp; &#x41; &#99999999;</p></body>",
    "<div id=\"x\" class='a b c' style=\"width: 100px; --v: #fff;\" disabled>",
    "<svg viewBox='0 0 24 24'><path d='M0 0'/><circle cx=12 cy=12 r=5>",
    "<textarea>raw <not-a-tag> &lt;ok&gt;</textarea>",
    "<select><option>One</option><option selected>Two</option></select>",
    "<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>",
    "<script>const a = 1;</script>",
    "<div onclick='x()'>bad</div>",
    "<a href='javascript:alert(1)'>bad</a>",
    "<> </ > <div = = '' \"\" //><<>>",
    "<div>Привет 🌍 日本語 &nbsp; &#x1F680;</div>"
  ]

  CssSeeds = [
    "",
    "\0\0",
    ":root { --a: var(--b, #112233); --b: var(--a, #445566); }",
    ".card { background: linear-gradient(135deg, #4F46E5 0%, rgba(16,185,129,0.5) 100%); box-shadow: 0 4px 12px #00000080; }",
    "@media (min-width: 600px) and (prefers-color-scheme: dark) { #id > .cls:focus { width: 50%; margin: 10px auto; } }",
    "@media ((((()))) { .x { color: red } }",
    "div > > + ~ * .#::before [attr=\"a>b\"]:nth-child(2n+1):hover:disabled { opacity: 0.5; z-index: -9999999999999; }",
    "/* unclosed comment .a { color: red; }",
    "p { color: rgb(999, -20, 128%); background: hsl(720deg, 150%, -10%); font-size: 1e99px; }",
    "button:disabled { padding: ; margin: auto auto auto auto; flex: 1 0 100px; }"
  ]

  JsSeeds = [
    "",
    "\0\0",
    "\"use strict\"; const a = `x=${1 === 1}`;",
    "var x = 1; if (x == 2) eval('1');",
    "/* unclosed comment",
    "// line comment\nconst rx = /abc\\/def[\\]/gi;",
    "const s = 'unterminated\nconst t = `unterminated ${a + { b: 1 }`;",
    "const fn = (a, b) => a !== b ? Nim.call('x') : setTimeout(() => {}, 10);",
    "const o = { var: 1, eval: 2 }; o.__proto__ = {};",
    "const emoji = '🚀 Привет'; console.log(emoji);"
  ]

  HtmlNoiseTokens = [
    "<", ">", "/", "=", "\"", "'", "&", ";", "!", "-", "div", "span", "script",
    "style", "textarea", "svg", "img", "br", "hr", "table", "tr", "td", "select",
    "option", "onclick", "javascript:", "data-caps", "<!--", "-->", "\0", "\n",
    " ", "&#x41;", "&amp;", "🌍", "Я"
  ]

  CssNoiseTokens = [
    "{", "}", "(", ")", ":", ";", ",", ".", "#", "*", ">", "+", "~", "[", "]",
    "@media", "@keyframes", "var(", "--x", "linear-gradient(", "rgb(", "hsl(",
    "px", "rem", "%", "auto", "none", ":hover", ":focus", ":disabled", ":root",
    "::before", "/*", "*/", "\"", "'", "\0", "\n", " ", "1e40", "-99"
  ]

  JsNoiseTokens = [
    "const ", "let ", "var ", "==", "===", "!=", "!==", "eval", "Function",
    "with", "__proto__", "setTimeout", "Nim", "document", "ui", "console",
    "`", "${", "}", "{", "(", ")", "/", "//", "/*", "*/", "\"", "'", "\\",
    "\0", "\n", " ", "🚀"
  ]

proc mutateInput(rng: var FuzzRng, seeds: openArray[string], tokens: openArray[string]): string {.raises: [].} =
  let mode = rng.nextInt(4)
  if mode == 0:
    # Pure random token soup
    let count = 1 + rng.nextInt(18)
    result = newStringOfCap(count * 5)
    for _ in 0 ..< count:
      result.add(tokens[rng.nextInt(tokens.len)])
    return

  var base = seeds[rng.nextInt(seeds.len)]
  if base.len == 0:
    return tokens[rng.nextInt(tokens.len)]

  case mode
  of 1:
    # Random byte/slice splice
    let cutA = rng.nextInt(base.len + 1)
    let cutB = cutA + rng.nextInt(base.len - cutA + 1)
    let ins = tokens[rng.nextInt(tokens.len)]
    result = base[0 ..< cutA] & ins & base[cutB ..< base.len]
  of 2:
    # Random byte corruption including null bytes and high UTF-8 bytes
    result = base
    let edits = 1 + rng.nextInt(4)
    for _ in 0 ..< edits:
      if result.len > 0:
        let idx = rng.nextInt(result.len)
        let b = rng.nextInt(256)
        result[idx] = char(b)
  else:
    # Truncation + repetition
    let cut = rng.nextInt(base.len + 1)
    let reps = 1 + rng.nextInt(3)
    result = ""
    for _ in 0 ..< reps:
      result.add(base[0 ..< cut])

proc runTortureEdgeCases() {.raises: [].} =
  # 1. HTML nesting depth bomb (4,000 nested <div> tags)
  var depthHtml = newStringOfCap(4000 * 5 + 4000 * 6)
  for _ in 0 ..< 4000:
    depthHtml.add("<div>")
  depthHtml.add("leaf")
  for _ in 0 ..< 4000:
    depthHtml.add("</div>")

  let depthDocRes = parseHtmlDoc(depthHtml)
  doAssert depthDocRes.isOk()
  let depthDoc = depthDocRes.get()
  doAssert depthDoc.innerText(depthDoc.root()) == "leaf"

  # Mount depth bomb into UiTree (bounded by MaxMountDepth without stack overflow)
  var tree = initUiTree(defaultHeapAllocator())
  defer: tree.destroy()
  var rt = initReactiveRuntime(defaultHeapAllocator())
  defer: rt.destroy()
  var bindings = initHtmlBindingRegistry()
  defer: bindings.destroy()
  let emptySheet = parseCssSheet("")
  let mRes = mountHtml(tree, addr rt, depthDoc, emptySheet, bindings)
  doAssert mRes.isOk()

  # 2. CSS @media & brace depth bomb (2,000 nested @media blocks)
  var depthCss = newStringOfCap(2000 * 18)
  for _ in 0 ..< 2000:
    depthCss.add("@media all { ")
  depthCss.add(".a { color: red; }")
  for _ in 0 ..< 2000:
    depthCss.add(" }")
  let depthSheet = parseCssSheet(depthCss)
  doAssert depthSheet.rules.len == 0

  # 3. Cyclic CSS var() bomb
  let cycCss = ":root { --a: var(--b); --b: var(--c); --c: var(--a, #123456); } #x { color: var(--a); }"
  let cycDoc = parseHtmlDoc("<div id='x'>Hi</div>").get()
  let cycSheet = parseCssSheet(cycCss)
  let st = computeNodeStyle(cycDoc, cycDoc.findById("x").get(), cycSheet, defaultRootStyle())
  doAssert st.fgColor == 0x123456FF'u32

  # 4. Template literal nesting bomb in JS validator
  var tplJs = newStringOfCap(2000)
  for _ in 0 ..< 250:
    tplJs.add("`${")
  tplJs.add("1 === 1")
  for _ in 0 ..< 250:
    tplJs.add("}`")
  let tplRes = validateJsPhilosophy(tplJs)
  doAssert tplRes.isOk()

  # 5. Empty & null-byte inputs
  doAssert parseHtmlDoc("").isOk()
  doAssert parseHtmlDoc("\0\0\0").isOk()
  doAssert parseCssSheet("\0\0\0").rules.len == 0
  doAssert parseCssColor("\0").isNone()
  doAssert parseCssLength("\0").isNone()
  doAssert validateJsPhilosophy("\0\0").isOk()

proc runFuzzSuite() {.raises: [].} =
  runTortureEdgeCases()

  var rng = initFuzzRng(0x9E3779B97F4A7C15'u64)
  let cfg = defaultJsValidationConfig()
  let dummyVars = @[
    CssCustomVar(name: "--a", value: "var(--b, #fff)"),
    CssCustomVar(name: "--b", value: "var(--a)")
  ]

  var htmlOkCount = 0
  var cssRulesTotal = 0
  var jsOkCount = 0

  const TotalIterations = 100_000
  for i in 0 ..< TotalIterations:
    let hIn = mutateInput(rng, HtmlSeeds, HtmlNoiseTokens)
    let hRes = parseHtmlDoc(hIn, allowJs = (i and 1) == 1)
    if hRes.isOk():
      inc htmlOkCount
      let doc = hRes.get()
      let _ = doc.innerText(doc.root())
      let _ = doc.findById("x")

    let cIn = mutateInput(rng, CssSeeds, CssNoiseTokens)
    let sheet = parseCssSheet(cIn)
    cssRulesTotal += sheet.rules.len
    let _ = parseCssColor(cIn)
    let _ = parseCssLength(cIn)
    let _ = parseCssDeclarations(cIn)
    let _ = resolveCssVars(cIn, dummyVars)

    let jIn = mutateInput(rng, JsSeeds, JsNoiseTokens)
    let jRes = validateJsPhilosophy(jIn, cfg)
    if jRes.isOk():
      inc jsOkCount
    let _ = parseScriptCaps(jIn)

  doAssert htmlOkCount > 0
  doAssert cssRulesTotal > 0
  doAssert jsOkCount > 0
  echo "  [PASS] 100,000 deterministic fuzz inputs across HTML5, CSS3, and JS validator completed (0 crashes, 0 hangs, 0 exceptions)."
  echo "         Stats: htmlOk=", htmlOkCount, " cssRules=", cssRulesTotal, " jsOk=", jsOkCount

proc main() =
  echo "================================================================="
  echo ">>> STARTING 100,000-INPUT HTML/CSS/JS DETERMINISTIC FUZZER <<<"
  echo "================================================================="
  runFuzzSuite()
  echo "================================================================="
  echo ">>> [SUCCESS] FUZZ SUITE PASSED CLEANLY! <<<"
  echo "================================================================="

when isMainModule:
  main()
