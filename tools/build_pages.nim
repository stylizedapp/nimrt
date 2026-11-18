## tools/build_pages — Static Portal Generator for GitHub Pages Deployment
##
## Builds `htmldocs/index.html`, copies `docs/html_css_manifest.json`, and creates `.nojekyll`
## alongside `nim doc` API reference output (`corex`, `algx`, `nimui`, `sdk`).

import std/[os, json, strutils]

proc renderTags(items: JsonNode, badgeClass: string): string =
  result = ""
  if items.isNil or items.kind != JArray:
    return
  for item in items:
    let text = item.getStr()
      .replace("&", "&amp;")
      .replace("<", "&lt;")
      .replace(">", "&gt;")
    result.add("<span class=\"tag " & badgeClass & "\">" & text & "</span>")

proc renderManifestSection(title: string, sec: JsonNode): string =
  if sec.isNil or sec.kind != JObject:
    return ""
  let sup = renderTags(sec{"supported"}, "tag-ok")
  let parsed = renderTags(sec{"parsedOnly"}, "tag-warn")
  let unsup = renderTags(sec{"unsupported"}, "tag-err")
  result = "<div class=\"manifest-card\">"
  result.add("<h3>" & title & "</h3>")
  if sup.len > 0:
    result.add("<div class=\"row\"><span class=\"lbl\">Supported</span><div class=\"tags\">" & sup & "</div></div>")
  if parsed.len > 0:
    result.add("<div class=\"row\"><span class=\"lbl\">Parsed Only</span><div class=\"tags\">" & parsed & "</div></div>")
  if unsup.len > 0:
    result.add("<div class=\"row\"><span class=\"lbl\">Unsupported (Explicit Error)</span><div class=\"tags\">" & unsup & "</div></div>")
  result.add("</div>")

proc main() =
  let outDir = "htmldocs"
  createDir(outDir)

  let manifestPath = "docs/html_css_manifest.json"
  var manifestRaw = "{}"
  if fileExists(manifestPath):
    manifestRaw = readFile(manifestPath)
    writeFile(outDir / "html_css_manifest.json", manifestRaw)

  let manifest = parseJson(manifestRaw)
  let sectionsHtml =
    renderManifestSection("HTML Tags", manifest{"tags"}) &
    renderManifestSection("Attributes", manifest{"attributes"}) &
    renderManifestSection("CSS Selectors", manifest{"selectors"}) &
    renderManifestSection("CSS Properties", manifest{"properties"}) &
    renderManifestSection("Events", manifest{"events"})

  let html = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>NimRT v04.03.03 — Docs, Compatibility &amp; Metrics</title>
  <style>
    :root {
      color-scheme: dark light;
      --bg: #0c0d10;
      --surface: #14161b;
      --border: #262933;
      --fg: #eef0f4;
      --muted: #98a0b0;
      --ok-bg: #12281c;
      --ok-fg: #7de8a6;
      --warn-bg: #292211;
      --warn-fg: #f3c868;
      --err-bg: #2b1418;
      --err-fg: #f58c96;
      --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      --sans: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
    }
    @media (prefers-color-scheme: light) {
      :root {
        --bg: #f8f9fb;
        --surface: #ffffff;
        --border: #dfe3eb;
        --fg: #12151c;
        --muted: #586070;
        --ok-bg: #e7f7ed;
        --ok-fg: #136c37;
        --warn-bg: #fef6e0;
        --warn-fg: #8c5c06;
        --err-bg: #fdebec;
        --err-fg: #a11c2a;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: var(--sans);
      background: var(--bg);
      color: var(--fg);
      line-height: 1.55;
    }
    main {
      max-width: 1080px;
      margin: 0 auto;
      padding: 40px 20px 64px;
    }
    header {
      border-bottom: 1px solid var(--border);
      padding-bottom: 24px;
      margin-bottom: 32px;
    }
    .pill {
      display: inline-block;
      font-family: var(--mono);
      font-size: 12px;
      padding: 3px 10px;
      border: 1px solid var(--border);
      border-radius: 999px;
      color: var(--muted);
      margin-bottom: 10px;
    }
    h1 { margin: 0 0 8px; font-size: 2rem; letter-spacing: -0.02em; }
    h2 { margin: 36px 0 14px; font-size: 1.25rem; }
    h3 { margin: 0 0 12px; font-size: 1rem; }
    p { color: var(--muted); margin: 0 0 14px; }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
      gap: 14px;
    }
    .card, .manifest-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 16px;
    }
    .manifest-card { margin-bottom: 14px; }
    .card a {
      color: var(--fg);
      text-decoration: none;
      font-weight: 600;
      display: block;
      margin-bottom: 6px;
    }
    .card a:hover { text-decoration: underline; }
    pre {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 14px;
      overflow-x: auto;
      font-family: var(--mono);
      font-size: 13px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      overflow: hidden;
      font-size: 14px;
    }
    th, td {
      text-align: left;
      padding: 10px 14px;
      border-bottom: 1px solid var(--border);
    }
    th { color: var(--muted); font-weight: 600; }
    .row { margin-bottom: 10px; }
    .lbl {
      display: block;
      font-size: 12px;
      font-weight: 600;
      color: var(--muted);
      margin-bottom: 6px;
    }
    .tags { display: flex; flex-wrap: wrap; gap: 6px; }
    .tag {
      font-family: var(--mono);
      font-size: 12px;
      padding: 2px 8px;
      border-radius: 6px;
    }
    .tag-ok { background: var(--ok-bg); color: var(--ok-fg); }
    .tag-warn { background: var(--warn-bg); color: var(--warn-fg); }
    .tag-err { background: var(--err-bg); color: var(--err-fg); }
    .actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 14px; }
    .btn {
      display: inline-block;
      padding: 8px 14px;
      border: 1px solid var(--border);
      border-radius: 8px;
      color: var(--fg);
      background: var(--surface);
      text-decoration: none;
      font-size: 14px;
      font-weight: 500;
    }
    .btn:hover { border-color: var(--fg); }
  </style>
</head>
<body>
  <main>
    <header>
      <span class="pill">v04.03.03 (SemVer 4.3.3) &bull; Windows-First Native Runtime</span>
      <h1>NimRT Documentation &amp; Compatibility Portal</h1>
      <p>Zero-overhead systems foundation (CoreX/AlgX), Vulkan 1.1+ SDF UI engine with CPU fallback (NimUI), Component SDK, and experimental <code>nim_safe</code> compiler.</p>
      <div class="actions">
        <a class="btn" href="https://github.com/stylizedapp/nimrt/releases">Download Portable Windows Releases (.zip / .exe)</a>
        <a class="btn" href="https://github.com/stylizedapp/nimrt/pkgs/container/nimrt-safe">Container Package (ghcr.io/stylizedapp/nimrt-safe)</a>
        <a class="btn" href="./html_css_manifest.json">Raw html_css_manifest.json</a>
      </div>
    </header>

    <h2>Container Package (GitHub Packages)</h2>
    <pre>docker pull ghcr.io/stylizedapp/nimrt-safe:latest
docker run --rm -v "$PWD:/workspace" ghcr.io/stylizedapp/nimrt-safe:latest c --mem-safe --safe-mode app.nim</pre>

    <h2>API Reference (<code>nim doc</code>)</h2>
    <div class="grid">
      <div class="card"><a href="./corex.html">CoreX Systems Core</a><p>Allocators, Result/Option, IOCP async, Chase-Lev pool, reactive signals, strict MFT.</p></div>
      <div class="card"><a href="./algx.html">AlgX Algorithms</a><p>UltraSort, SwissMap (FastMap), ZeroPack streaming JSON/binary, SIMD scan.</p></div>
      <div class="card"><a href="./nimui.html">NimUI &amp; Vulkan SDF</a><p>O(N) Flexbox layout, Vulkan 1.1+ SDF + CPU fallback, HTML5/CSS3 subset, QuickJS sandbox.</p></div>
      <div class="card"><a href="./nimui/sdk.html">Component SDK &amp; Index</a><p>11 UI blocks, 6 system blocks, default-deny permissions, SemVer BlockRegistry (<a style="display:inline" href="./theindex.html">Symbol Index</a>).</p></div>
    </div>

    <h2>Verified Canonical Benchmarks &amp; Binary Sizes</h2>
    <table>
      <thead><tr><th>Metric</th><th>Layer</th><th>Measured Result</th></tr></thead>
      <tbody>
        <tr><td><code>wiztree.exe</code> size / warm <code>--help</code></td><td>CLI App</td><td>475,844 B &bull; 22.14 ms warm</td></tr>
        <tr><td><code>canonical_bench.exe</code> size / peak RSS</td><td>Full App</td><td>977,540 B &bull; 33.7 MB RSS peak</td></tr>
        <tr><td><code>ui_minimal_layout_draw</code> (p50)</td><td>UI Engine</td><td>0.019 ms</td></tr>
        <tr><td><code>ui_table_200x6_layout_draw</code> (p50)</td><td>UI Engine</td><td>0.722 ms</td></tr>
        <tr><td><code>ui_virtuallist_100k_scroll</code> (p50)</td><td>UI Engine</td><td>0.092 ms</td></tr>
        <tr><td><code>algx_ultrasort_1m</code> (p50)</td><td>CoreX / AlgX</td><td>76.30 ms</td></tr>
        <tr><td>Full test suite (<code>nimble test_all</code> + UI + SDK)</td><td>CI Gate</td><td>40/40 targets + 6/6 UI + 4/4 SDK (0 leaks)</td></tr>
      </tbody>
    </table>

    <h2>HTML5 / CSS3 Compatibility Manifest</h2>
    <p>Machine-readable source of truth: <a href="./html_css_manifest.json"><code>html_css_manifest.json</code></a>. Unsupported constructs emit explicit compile/validation errors.</p>
    """ & sectionsHtml & """
  </main>
</body>
</html>
"""

  writeFile(outDir / "index.html", html)
  writeFile(outDir / ".nojekyll", "")
  echo "[pages] Generated ", outDir / "index.html", ", ", outDir / "html_css_manifest.json", ", ", outDir / ".nojekyll"

when isMainModule:
  main()
