## src/nimui/html/manifest.nim
##
## Machine-readable HTML5/CSS3 compatibility manifest, supported vs. parsed-only
## vs. unsupported feature classification, UnknownCssPolicy, and explicit
## unsupported-feature diagnostics (CSS Grid, :has(), <canvas>, etc.).

import corex/result
import ./types

type
  FeatureSupportLevel* = enum
    fslSupported
    fslParsedOnly
    fslUnsupported

  UnknownCssPolicy* = enum
    ucpWarnOnce
    ucpIgnore
    ucpError

const
  ManifestEngineVersion* = "0.1.0"
  ManifestMaxInstancesPerFrame* = 16384
  ManifestMaxCssVarDepth* = 16
  ManifestMaxMediaRecursionDepth* = 8
  ManifestMaxLayoutDepth* = 256

  SupportedHtmlTags* = [
    "html", "head", "body", "style",
    "div", "section", "main", "header", "footer", "nav", "aside", "article", "form",
    "ul", "ol", "li",
    "p", "span", "h1", "h2", "h3", "h4", "h5", "h6",
    "label", "strong", "b", "em", "i", "code", "pre", "a",
    "button", "input", "textarea", "hr", "br"
  ]

  ParsedOnlyHtmlTags* = [
    "title", "meta", "link", "img", "table", "thead", "tbody", "tr", "th", "td", "small"
  ]

  UnsupportedHtmlTags* = [
    "canvas", "svg", "iframe", "video", "audio", "object", "embed", "script"
  ]

  SupportedHtmlAttributes* = [
    "id", "class", "style", "type", "placeholder", "value", "disabled", "readonly",
    "data-bind-text", "data-bind-input", "data-on-click", "data-on-input", "data-caps"
  ]

  ParsedOnlyHtmlAttributes* = [
    "href", "src", "alt", "title", "name", "for", "role", "tabindex", "aria-label", "data-*"
  ]

  UnsupportedHtmlAttributes* = [
    "on*", "javascript: (href/src/action/formaction)"
  ]

  SupportedCssSelectors* = [
    "*", "tag", ".class", "#id", "A B (descendant)", "A > B (direct-child)",
    ":hover", ":active", ":focus", ":focus-visible", ":focus-within", ":disabled", ":root"
  ]

  ParsedOnlyCssSelectors* = [
    "@media (min-width, max-width, prefers-color-scheme)"
  ]

  UnsupportedCssSelectors* = [
    ":has()", ":is()", ":where()", ":nth-child()", ":first-child", ":last-child",
    "::before", "::after", "[attr]", "A + B", "A ~ B"
  ]

  SupportedCssProperties* = [
    "display (block|flex|inline|inline-block|none)",
    "flex-direction", "justify-content", "align-items", "align-self", "flex", "flex-grow", "flex-basis",
    "gap", "row-gap", "column-gap",
    "width", "height", "min-width", "max-width", "min-height", "max-height",
    "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
    "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
    "color", "background", "background-color", "background-image", "opacity",
    "border", "border-width", "border-color", "border-style",
    "border-top", "border-right", "border-bottom", "border-left",
    "border-radius", "box-shadow",
    "font-size", "text-align", "overflow", "overflow-y", "z-index",
    "--* (custom properties)", "var()"
  ]

  ParsedOnlyCssProperties* = [
    "position", "top", "right", "bottom", "left",
    "flex-wrap", "flex-shrink",
    "font-weight", "font-family", "line-height",
    "cursor", "text-overflow", "white-space",
    "list-style", "list-style-type",
    "transition", "transition-property", "transition-duration",
    "transition-timing-function", "transition-delay",
    "box-sizing"
  ]

  UnsupportedCssProperties* = [
    "display:grid", "display:inline-grid", "grid", "grid-template-columns",
    "grid-template-rows", "grid-template-areas", "grid-column", "grid-row",
    "grid-area", "grid-auto-flow", "float", "clear", "transform", "animation",
    "filter", "backdrop-filter", "clip-path"
  ]

  SupportedEvents* = [
    "data-on-click", "data-on-input", "click (QuickJS opt-in)", "input (QuickJS opt-in)"
  ]

  UnsupportedEvents* = [
    "onclick (inline)", "oninput (inline)", "onload (inline)", "on* (inline HTML attributes)"
  ]

proc strInList(s: string, list: openArray[string]): bool {.raises: [].} =
  for item in list:
    if item == s:
      return true
  false

proc startsWithAscii(s, prefix: string): bool {.inline, raises: [].} =
  if s.len < prefix.len:
    return false
  for i in 0 ..< prefix.len:
    if s[i] != prefix[i]:
      return false
  true

proc classifyTag*(tag: string): FeatureSupportLevel {.raises: [].} =
  let low = htmlToLowerAscii(htmlStripAscii(tag))
  if strInList(low, SupportedHtmlTags):
    return fslSupported
  if strInList(low, ParsedOnlyHtmlTags):
    return fslParsedOnly
  fslUnsupported

proc classifyCssProperty*(prop: string): FeatureSupportLevel {.raises: [].} =
  let low = htmlToLowerAscii(htmlStripAscii(prop))
  if low == "display":
    return fslSupported
  if low == "display:grid" or low == "display:inline-grid" or startsWithAscii(low, "grid"):
    return fslUnsupported
  for item in SupportedCssProperties:
    if item == low:
      return fslSupported
  if startsWithAscii(low, "--"):
    return fslSupported
  if strInList(low, ParsedOnlyCssProperties):
    return fslParsedOnly
  fslUnsupported

proc classifyCssSelector*(rawSel: string): FeatureSupportLevel {.raises: [].} =
  let low = htmlToLowerAscii(htmlStripAscii(rawSel))
  if startsWithAscii(low, ":has(") or low == ":has" or
     startsWithAscii(low, ":is(") or startsWithAscii(low, ":where(") or
     startsWithAscii(low, ":nth-") or startsWithAscii(low, "::") or
     startsWithAscii(low, "["):
    return fslUnsupported
  fslSupported

proc unsupportedTagMessage*(tag: string): string {.raises: [].} =
  let low = htmlToLowerAscii(htmlStripAscii(tag))
  case low
  of "canvas":
    "Unsupported HTML tag '<canvas>': 2D/WebGL canvas is not supported; use NimUI SDF primitives or HTML/CSS elements"
  of "svg":
    "Unsupported HTML tag '<svg>': inline SVG vector paths are not supported; use NimUI SDF shapes or font glyphs"
  of "iframe":
    "Unsupported HTML tag '<iframe>': nested browsing contexts are not supported"
  of "video", "audio":
    "Unsupported HTML tag '<" & low & ">': media playback elements are not supported"
  of "object", "embed":
    "Unsupported HTML tag '<" & low & ">': external plugin embeds are not supported"
  of "script":
    "Zero-JS policy violation: <script> tag is forbidden unless allowJs=true"
  else:
    "Unsupported HTML tag '<" & low & ">': not in NimUI supported/parsed-only tag manifest"

proc unsupportedSelectorMessage*(rawPseudo: string): string {.raises: [].} =
  let low = htmlToLowerAscii(htmlStripAscii(rawPseudo))
  if startsWithAscii(low, ":has"):
    return "Unsupported CSS selector ':has()': relational pseudo-class is not supported"
  if startsWithAscii(low, "::"):
    return "Unsupported CSS pseudo-element '" & rawPseudo & "': pseudo-elements are not supported"
  if startsWithAscii(low, "["):
    return "Unsupported CSS attribute selector '" & rawPseudo & "': attribute selectors are not supported"
  "Unsupported CSS selector '" & rawPseudo & "': selector is not supported"

proc unsupportedCssPropertyMessage*(prop: string): string {.raises: [].} =
  let low = htmlToLowerAscii(htmlStripAscii(prop))
  if low == "display:grid" or low == "display:inline-grid" or startsWithAscii(low, "grid"):
    return "Unsupported CSS feature 'CSS Grid' (" & low & "): use Flexbox ('display: flex')"
  "Unsupported CSS property '" & low & "': property is not supported"

proc validateHtmlCssCompatibility*(
  doc: HtmlDoc,
  sheet: CssStylesheet,
  policy: UnknownCssPolicy = ucpWarnOnce
): Result[void, seq[string]] {.raises: [].} =
  ## Validates a parsed HtmlDoc + CssStylesheet against the NimUI compatibility manifest.
  ## Always rejects explicitly unsupported HTML tags (<canvas>, <svg>, <iframe>, etc.),
  ## unsupported CSS selectors (:has(), ::before, etc.), and CSS Grid.
  ## Unknown CSS properties are governed by `policy` (ucpWarnOnce, ucpIgnore, ucpError).
  var errors: seq[string] = @[]

  for node in doc.nodes:
    if node.kind == hnkElement:
      if classifyTag(node.tag) == fslUnsupported:
        let msg = unsupportedTagMessage(node.tag)
        if msg notin errors:
          errors.add(msg)

  for sel in sheet.unsupportedSelectors:
    let msg = unsupportedSelectorMessage(sel)
    if msg notin errors:
      errors.add(msg)

  for prop in sheet.unsupportedProperties:
    let low = htmlToLowerAscii(htmlStripAscii(prop))
    let isGrid = low == "display:grid" or low == "display:inline-grid" or startsWithAscii(low, "grid")
    if isGrid or policy == ucpError:
      let msg = unsupportedCssPropertyMessage(low)
      if msg notin errors:
        errors.add(msg)

  if errors.len > 0:
    return err[void, seq[string]](errors)
  ok[void, seq[string]]()

proc appendJsonStringArray(outStr: var string, items: openArray[string], indent: string) {.raises: [].} =
  outStr.add("[\n")
  for i in 0 ..< items.len:
    outStr.add(indent & "  \"")
    for c in items[i]:
      if c == '"':
        outStr.add("\\\"")
      elif c == '\\':
        outStr.add("\\\\")
      else:
        outStr.add(c)
    outStr.add("\"")
    if i + 1 < items.len:
      outStr.add(",")
    outStr.add("\n")
  outStr.add(indent & "]")

proc buildHtmlCssManifestJson*(): string {.raises: [].} =
  ## Generates the deterministic machine-readable JSON compatibility manifest.
  result = "{\n"
  result.add("  \"engine\": \"nimui-html-css\",\n")
  result.add("  \"version\": \"" & ManifestEngineVersion & "\",\n")
  result.add("  \"unknownCssPolicyDefault\": \"warn-once\",\n")
  result.add("  \"unknownCssPolicies\": [\"warn-once\", \"ignore\", \"error\"],\n")

  result.add("  \"tags\": {\n")
  result.add("    \"supported\": ")
  result.appendJsonStringArray(SupportedHtmlTags, "    ")
  result.add(",\n    \"parsedOnly\": ")
  result.appendJsonStringArray(ParsedOnlyHtmlTags, "    ")
  result.add(",\n    \"unsupported\": ")
  result.appendJsonStringArray(UnsupportedHtmlTags, "    ")
  result.add("\n  },\n")

  result.add("  \"attributes\": {\n")
  result.add("    \"supported\": ")
  result.appendJsonStringArray(SupportedHtmlAttributes, "    ")
  result.add(",\n    \"parsedOnly\": ")
  result.appendJsonStringArray(ParsedOnlyHtmlAttributes, "    ")
  result.add(",\n    \"unsupported\": ")
  result.appendJsonStringArray(UnsupportedHtmlAttributes, "    ")
  result.add("\n  },\n")

  result.add("  \"selectors\": {\n")
  result.add("    \"supported\": ")
  result.appendJsonStringArray(SupportedCssSelectors, "    ")
  result.add(",\n    \"parsedOnly\": ")
  result.appendJsonStringArray(ParsedOnlyCssSelectors, "    ")
  result.add(",\n    \"unsupported\": ")
  result.appendJsonStringArray(UnsupportedCssSelectors, "    ")
  result.add("\n  },\n")

  result.add("  \"properties\": {\n")
  result.add("    \"supported\": ")
  result.appendJsonStringArray(SupportedCssProperties, "    ")
  result.add(",\n    \"parsedOnly\": ")
  result.appendJsonStringArray(ParsedOnlyCssProperties, "    ")
  result.add(",\n    \"unsupported\": ")
  result.appendJsonStringArray(UnsupportedCssProperties, "    ")
  result.add("\n  },\n")

  result.add("  \"events\": {\n")
  result.add("    \"supported\": ")
  result.appendJsonStringArray(SupportedEvents, "    ")
  result.add(",\n    \"unsupported\": ")
  result.appendJsonStringArray(UnsupportedEvents, "    ")
  result.add("\n  },\n")

  result.add("  \"limits\": {\n")
  result.add("    \"maxInstancesPerFrame\": " & $ManifestMaxInstancesPerFrame & ",\n")
  result.add("    \"maxCssVarDepth\": " & $ManifestMaxCssVarDepth & ",\n")
  result.add("    \"maxMediaRecursionDepth\": " & $ManifestMaxMediaRecursionDepth & ",\n")
  result.add("    \"maxLayoutDepth\": " & $ManifestMaxLayoutDepth & ",\n")
  result.add("    \"zeroJsDefault\": true,\n")
  result.add("    \"noExternalNetwork\": true\n")
  result.add("  }\n")
  result.add("}\n")
