# NimUI HTML5 / CSS3 Compatibility & Boundaries

Machine-readable manifest: [`docs/html_css_manifest.json`](html_css_manifest.json)  
Validator & policy API: `src/nimui/html/manifest.nim` (`validateHtmlCssCompatibility`, `UnknownCssPolicy`, `buildHtmlCssManifestJson`)

## Support Tiers

NimUI separates all HTML tags, attributes, CSS selectors, and CSS properties into three explicit tiers:

1. **Supported (`fslSupported`)**: Parsed, cascaded, and compiled into `UiTree` layout/rendering/interactive bindings.
2. **Parsed-Only (`fslParsedOnly`)**: Parsed into the DOM/CSS AST without crashing, but either mapped to generic containers (`table`, `img`, `meta`, `title`) or stored on `CssComputedStyle` without visual/layout effect yet (`position`, `flex-wrap`, `font-weight`, `font-family`, `line-height`, `cursor`, `transition*`).
3. **Unsupported (`fslUnsupported`)**: Explicitly rejected with clear, actionable diagnostics by `validateHtmlCssCompatibility`:
   - **CSS Grid** (`display: grid`, `display: inline-grid`, `grid-*`): `"Unsupported CSS feature 'CSS Grid' (...): use Flexbox ('display: flex')"`
   - **`:has()` selector**: `"Unsupported CSS selector ':has()': relational pseudo-class is not supported"`
   - **`<canvas>` tag**: `"Unsupported HTML tag '<canvas>': 2D/WebGL canvas is not supported; use NimUI SDF primitives or HTML/CSS elements"`
   - Also `<svg>`, `<iframe>`, `<video>`, `<audio>`, `<object>`, `<embed>`, `::before`/`::after`, `[attr]`, `:nth-child()`.

## Unknown CSS Policy

`UnknownCssPolicy` controls how unknown CSS properties are handled:

- **`ucpWarnOnce`** (default): Unknown properties are deduplicated into `CssStylesheet.unsupportedProperties` and `CssComputedStyle.unsupportedProperties` so callers can log/surface them once per property without failing layout.
- **`ucpIgnore`**: Unknown properties are silently ignored; explicit unsupported features (CSS Grid, `:has()`, `<canvas>`) are still rejected by `validateHtmlCssCompatibility`.
- **`ucpError`**: Any unknown CSS property causes `validateHtmlCssCompatibility` to return an error.

## Limits & Security Boundaries

- **Zero-JS by default** (`allowJs = false`): `<script>`, inline `on*` attributes, and `javascript:` URIs are rejected at parse time.
- **No external network**: External `<script src=...>` is forbidden.
- **Bounded recursion & buffers**: `MaxInstancesPerFrame = 16384`, `MaxCssVarDepth = 16`, `MaxMediaRecursionDepth = 8`, `MaxLayoutDepth = 256`.
