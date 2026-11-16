#!/usr/bin/env python3
"""
Р“РµРЅРµСЂР°С‚РѕСЂ РёРЅС‚РµСЂР°РєС‚РёРІРЅРѕР№ С‚РµРјРЅРѕР№ HTML-РІРёС‚СЂРёРЅС‹: Nim (CoreX/AlgX) vs Rust.
Р’С‹С…РѕРґРЅРѕР№ С„Р°Р№Р»: showcase.html (Р°РІС‚РѕРЅРѕРјРЅС‹Р№, Р±РµР· РёРЅС‚РµСЂРЅРµС‚Р°).
"""

from pathlib import Path
import json

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Nim CoreX vs Rust Showcase</title>
  <style>
    :root {
      --bg: #090a0f;
      --card: #12141c;
      --card-border: #1f2330;
      --text: #e6edf3;
      --muted: #8b949e;
      --accent-nim: #f3b544;
      --accent-rust: #f74c00;
      --success: #2ea043;
      --code-bg: #0d1117;
      --font-mono: 'JetBrains Mono', 'Fira Code', 'SF Mono', Consolas, monospace;
      --font-ui: -apple-system, BlinkMacSystemFont, 'SF Pro Text', Inter, sans-serif;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: var(--font-ui);
      padding: 32px 20px;
      line-height: 1.5;
    }
    .container { max-width: 1200px; margin: 0 auto; display: flex; flex-direction: column; gap: 28px; }
    
    /* Header */
    header {
      display: flex;
      justify-content: space-between;
      align-items: flex-end;
      border-bottom: 1px solid var(--card-border);
      padding-bottom: 20px;
    }
    h1 { font-size: 24px; font-weight: 600; letter-spacing: -0.5px; }
    .badge {
      font-family: var(--font-mono);
      font-size: 12px;
      color: var(--muted);
      background: var(--card);
      padding: 4px 10px;
      border-radius: 6px;
      border: 1px solid var(--card-border);
    }

    /* KPI Grid */
    .kpi-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 16px;
    }
    .kpi-card {
      background: var(--card);
      border: 1px solid var(--card-border);
      border-radius: 10px;
      padding: 18px 20px;
    }
    .kpi-title { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
    .kpi-value { font-size: 28px; font-weight: 700; margin: 8px 0; font-family: var(--font-mono); }
    .kpi-val-nim { color: var(--accent-nim); }
    .kpi-val-rust { color: var(--accent-rust); }
    .kpi-diff { font-size: 13px; color: var(--success); font-weight: 500; }

    /* Chart Section */
    .panel {
      background: var(--card);
      border: 1px solid var(--card-border);
      border-radius: 10px;
      padding: 24px;
    }
    .panel-header {
      font-size: 16px;
      font-weight: 600;
      margin-bottom: 16px;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .chart-container { display: flex; flex-direction: column; gap: 14px; }
    .chart-row { display: flex; flex-direction: column; gap: 6px; }
    .chart-label { display: flex; justify-content: space-between; font-size: 13px; font-family: var(--font-mono); }
    .chart-bar-bg {
      background: #181c27;
      height: 26px;
      border-radius: 6px;
      overflow: hidden;
      display: flex;
    }
    .chart-bar {
      height: 100%;
      display: flex;
      align-items: center;
      padding-left: 10px;
      font-size: 12px;
      font-weight: 600;
      font-family: var(--font-mono);
      color: #000;
      transition: width 0.8s cubic-bezier(0.16, 1, 0.3, 1);
    }
    .bar-nim { background: var(--accent-nim); }
    .bar-rust { background: var(--accent-rust); color: #fff; }

    /* Code Comparison Side-by-Side */
    .code-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
    }
    @media (max-width: 850px) { .code-grid { grid-template-columns: 1fr; } }
    .code-box {
      background: var(--code-bg);
      border: 1px solid var(--card-border);
      border-radius: 8px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }
    .code-topbar {
      display: flex;
      justify-content: space-between;
      padding: 10px 14px;
      background: #141822;
      border-bottom: 1px solid var(--card-border);
      font-family: var(--font-mono);
      font-size: 12px;
    }
    pre {
      padding: 14px;
      font-family: var(--font-mono);
      font-size: 12.5px;
      line-height: 1.6;
      overflow-x: auto;
      color: #c9d1d9;
    }
    .kw { color: #ff7b72; font-weight: 600; }
    .fn { color: #d2a8ff; }
    .num { color: #79c0ff; }
    .cm { color: #8b949e; font-style: italic; }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div>
        <h1>Differential Performance &amp; Ergonomics Suite</h1>
        <p style="color: var(--muted); font-size: 14px; margin-top: 4px;">РЎРѕСЂС‚РёСЂРѕРІРєР° 10,000,000 СЌР»РµРјРµРЅС‚РѕРІ int64 (80 MB) РІ РѕРїРµСЂР°С‚РёРІРЅРѕР№ РїР°РјСЏС‚Рё вЂ” --mm:orc</p>
      </div>
      <div class="badge">AMD Ryzen 3 3200U (2C/4T) вЂў MinGW GCC 11.1 vs Rust MSVC вЂў LTO on</div>
    </header>

    <div class="kpi-grid">
      <div class="kpi-card">
        <div class="kpi-title">Min Sort Time (Nim, замер --mm:arc)</div>
        <div class="kpi-value kpi-val-nim">~77 ms</div>
        <div class="kpi-diff">РџР°СЂРёС‚РµС‚ СЃ Rust (~78 ms) РЅР° РѕРґРЅРѕРј СЃС‚РµРЅРґРµ (Warmup=2, Runs=11)</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">Binary Footprint</div>
        <div class="kpi-value">131 KB</div>
        <div class="kpi-diff">РќР° ~21% РєРѕРјРїР°РєС‚РЅРµРµ Rust (166 KB) РїСЂРё -flto -s</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">Algorithm LOC</div>
        <div class="kpi-value">307 СЃС‚СЂРѕРє</div>
        <div class="kpi-diff">РќР° ~30% РјРµРЅСЊС€Рµ Rust (442 СЃС‚СЂРѕРєРё РІ rust_ultra_showcase.rs)</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">Call-Site Unsafe</div>
        <div class="kpi-value" style="color: var(--success);">0</div>
        <div class="kpi-diff">РќРёР·РєРѕСѓСЂРѕРІРЅРµРІС‹Р№ РєРѕРґ (cast/ptr/checks:off) РёР·РѕР»РёСЂРѕРІР°РЅ РІ algx</div>
      </div>
    </div>

    <div class="panel">
      <div class="panel-header">
        <span>РџСЂРёРјРµС‡Р°РЅРёРµ Рє РјРµС‚РѕРґРёРєРµ Р·Р°РјРµСЂРѕРІ (Single-Machine Caveat)</span>
        <span style="font-size: 13px; color: var(--muted); font-family: var(--font-mono);">Windows 10/11 x64</span>
      </div>
      <p style="color: var(--muted); font-size: 13.5px; line-height: 1.6;">
        Р’СЃРµ СЃСЂР°РІРЅРµРЅРёСЏ РІС‹РїРѕР»РЅРµРЅС‹ РЅР° РѕРґРЅРѕР№ РјР°С€РёРЅРµ (AMD Ryzen 3 3200U, 2 СЏРґСЂР° / 4 РїРѕС‚РѕРєР°, ~6 Р“Р‘ РћР—РЈ).
        Nim РєРѕРјРїРёР»РёСЂСѓРµС‚СЃСЏ С‡РµСЂРµР· MinGW-W64 GCC 11.1.0 (<code>--mm:orc</code>), Rust вЂ” С‡РµСЂРµР· <code>x86_64-pc-windows-msvc</code> (LLVM 22.1.2).
        РР·-Р·Р° 2 С„РёР·РёС‡РµСЃРєРёС… СЏРґРµСЂ Р°Р±СЃРѕР»СЋС‚РЅС‹Рµ РјРёР»Р»РёСЃРµРєСѓРЅРґС‹ С‡СѓРІСЃС‚РІРёС‚РµР»СЊРЅС‹ Рє С„РѕРЅРѕРІРѕР№ РЅР°РіСЂСѓР·РєРµ РћРЎ; РґРѕРІРµСЂРёС‚РµР»СЊРЅС‹Рµ РёРЅС‚РµСЂРІР°Р»С‹ РїРѕ РјРЅРѕР¶РµСЃС‚РІРµРЅРЅС‹Рј РјР°С€РёРЅР°Рј РЅРµ СЃС‚СЂРѕРёР»РёСЃСЊ.
        РџРѕРґСЂРѕР±РЅР°СЏ С‚Р°Р±Р»РёС†Р° РїРѕ РІСЃРµРј 4 РґРёСЃС†РёРїР»РёРЅР°Рј (РІРєР»СЋС‡Р°СЏ РѕС‚СЃС‚Р°РІР°РЅРёРµ СЃРєР°Р»СЏСЂРЅРѕРіРѕ <code>FastMap</code> РѕС‚ <code>hashbrown</code> СЃ 16-Р±Р°Р№С‚РЅС‹Рј SSE2) РїСЂРёРІРµРґРµРЅР° РІ <code>docs/BENCHMARK_SHOWCASE.md</code>.
      </p>
    </div>

    <div class="panel">
      <div class="panel-header">
        <span>Р’СЂРµРјСЏ РІС‹РїРѕР»РЅРµРЅРёСЏ (РјРµРЅСЊС€Рµ вЂ” Р»СѓС‡С€Рµ, symmetric suite min)</span>
        <span style="font-size: 13px; color: var(--muted); font-family: var(--font-mono);">10M int64 (4 РїРѕС‚РѕРєР°)</span>
      </div>
      <div class="chart-container">
        <div class="chart-row">
          <div class="chart-label"><span>Nim algx/ultrasort (Hybrid MSD Radix + L1 Insertion)</span><span>76.98 ms</span></div>
          <div class="chart-bar-bg"><div class="chart-bar bar-nim" style="width: 16.4%;">76.98 ms</div></div>
        </div>
        <div class="chart-row">
          <div class="chart-label"><span>Rust Ultra (std::thread + Barrier + L1 MSD Radix)</span><span>78.07 ms</span></div>
          <div class="chart-bar-bg"><div class="chart-bar bar-rust" style="width: 16.6%;">78.07 ms</div></div>
        </div>
        <div class="chart-row">
          <div class="chart-label"><span>Rust std::slice::sort_unstable (PDQSort, 1T baseline)</span><span>469.00 ms</span></div>
          <div class="chart-bar-bg"><div class="chart-bar" style="background: #444c56; color: #fff; width: 100%;">469.00 ms</div></div>
        </div>
      </div>
    </div>

    <div class="panel">
      <div class="panel-header">
        <span>Side-by-Side: Р Р°Р·РІРµСЂС‚РєР° СЃСѓРїРµСЂСЃРєР°Р»СЏСЂРЅРѕРіРѕ 4-way РїРѕРґСЃС‡РµС‚Р° РіРёСЃС‚РѕРіСЂР°РјРјС‹</span>
      </div>
      <div class="code-grid">
        <div class="code-box">
          <div class="code-topbar">
            <span style="color: var(--accent-nim);">Nim (ultrasort.nim) вЂ” Р§РёСЃС‚С‹Р№ AST С€Р°Р±Р»РѕРЅ</span>
            <span class="badge">1 РІС‹Р·РѕРІ С€Р°Р±Р»РѕРЅР°</span>
          </div>
          <pre><code><span class="cm"># РЁР°Р±Р»РѕРЅ РІСЂРµРјРµРЅРё РєРѕРјРїРёР»СЏС†РёРё СЂР°Р·РІРѕСЂР°С‡РёРІР°РµС‚ 4x С†РёРєР»
# РїРѕРІРµСЂС… РІРЅСѓС‚СЂРµРЅРЅРµРіРѕ ptr UncheckedArray[int64] РІ algx</span>

<span class="fn">unrollHist4</span>(
  sIdx, eIdx, 
  st.hists[t], 
  <span class="kw">int</span>((<span class="kw">cast</span>[<span class="kw">uint64</span>](dataPtr[it]) <span class="kw">shr</span> Shift1) <span class="kw">xor</span> SignFlip)
)</code></pre>
        </div>

        <div class="code-box">
          <div class="code-topbar">
            <span style="color: var(--accent-rust);">Rust (rust_ultra_showcase.rs) вЂ” Р СѓС‡РЅРѕР№ unsafe</span>
            <span class="badge">Р‘РѕР№Р»РµСЂРїР»РµР№С‚ СѓРєР°Р·Р°С‚РµР»РµР№</span>
          </div>
          <pre><code><span class="cm">// РџСЂРёС…РѕРґРёС‚СЃСЏ РѕР±С…РѕРґРёС‚СЊ РїСЂРѕРІРµСЂРєРё РєРѕРјРїРёР»СЏС‚РѕСЂР°:</span>
<span class="kw">let</span> data_addr = data.<span class="fn">as_mut_ptr</span>() <span class="kw">as</span> <span class="kw">usize</span>;
<span class="kw">let</span> cur_ptr = (data_addr + s * <span class="num">8</span>) <span class="kw">as</span> *<span class="kw">const</span> <span class="kw">i64</span>;

<span class="kw">unsafe</span> {
  <span class="kw">let</span> v = *cur_ptr;
  <span class="kw">let</span> b = ((v <span class="kw">as</span> <span class="kw">u64</span> >> Shift1) ^ SignFlip) <span class="kw">as</span> <span class="kw">usize</span>;
  *my_hist.<span class="fn">get_unchecked_mut</span>(b) += <span class="num">1</span>;
  <span class="cm">// ... РґСѓР±Р»РёСЂСѓРµС‚СЃСЏ 4 СЂР°Р·Р° РІСЂСѓС‡РЅСѓСЋ</span>
}</code></pre>
        </div>
      </div>
    </div>
  </div>
</body>
</html>
"""

def main():
    output_path = Path(__file__).parent / "showcase.html"
    output_path.write_text(HTML_TEMPLATE, encoding="utf-8")
    print(f"[OK] Р’РёС‚СЂРёРЅР° СѓСЃРїРµС€РЅРѕ СЃРіРµРЅРµСЂРёСЂРѕРІР°РЅР°: {output_path.resolve()}")

if __name__ == "__main__":
    main()
