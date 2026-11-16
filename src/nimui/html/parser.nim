## src/nimui/html/parser.nim
##
## HTML5 DOM parser, entity decoder, DOM query helpers, and Zero-JS /
## Zig-Explicitness security enforcement.

import corex/adt
import corex/result
import ./types

proc root*(doc: HtmlDoc): int {.inline, raises: [].} =
  if doc.nodes.len > 0: 0 else: -1

proc getAttr*(node: HtmlNode, attrName: string): Option[string] {.raises: [].} =
  let key = htmlToLowerAscii(attrName)
  for a in node.attrs:
    if a.name == key:
      return some(a.value)
  none[string]()

proc hasClass*(node: HtmlNode, cls: string): bool {.raises: [].} =
  for c in node.classes:
    if c == cls:
      return true
  false

proc innerText*(doc: HtmlDoc, nodeIdx: int): string {.raises: [].} =
  ## Iterative pre-order text collector (safe against arbitrary DOM nesting depth).
  if nodeIdx < 0 or nodeIdx >= doc.nodes.len:
    return ""
  if doc.nodes[nodeIdx].kind == hnkText:
    return doc.nodes[nodeIdx].text

  result = ""
  var stack: seq[int] = @[nodeIdx]
  while stack.len > 0:
    let cur = stack.pop()
    if cur < 0 or cur >= doc.nodes.len:
      continue
    let node = doc.nodes[cur]
    if node.kind == hnkText:
      result.add(node.text)
    else:
      for i in countdown(node.children.len - 1, 0):
        stack.add(node.children[i])

proc findById*(doc: HtmlDoc, id: string): Option[int] {.raises: [].} =
  for i in 0 ..< doc.nodes.len:
    if doc.nodes[i].kind == hnkElement and doc.nodes[i].id == id:
      return some(i)
  none[int]()

proc isForbiddenEventAttr*(attrName: string): bool {.inline, raises: [].} =
  # Inline JS event handlers follow on<event> (e.g., onclick, oninput, onload).
  attrName.len > 2 and attrName[0] == 'o' and attrName[1] == 'n' and isAlphaAscii(attrName[2])

proc isJavascriptUrl*(val: string): bool {.raises: [].} =
  let t = htmlStripAscii(val)
  htmlStartsWithIgnoreCase(t, "javascript:")

proc parseHtmlDoc*(html: string, allowJs: bool = false): Result[HtmlDoc, string] {.raises: [].} =
  var doc = HtmlDoc(
    nodes: @[HtmlNode(kind: hnkDocument, parent: -1, children: @[])],
    embeddedCss: "",
    scripts: @[]
  )
  var stack: seq[int] = @[0]
  var pos = 0

  while pos < html.len:
    if html[pos] == '<':
      # 1. HTML comment <!-- ... -->
      if pos + 3 < html.len and html[pos + 1] == '!' and html[pos + 2] == '-' and html[pos + 3] == '-':
        var closePos = pos + 4
        while closePos + 2 < html.len:
          if html[closePos] == '-' and html[closePos + 1] == '-' and html[closePos + 2] == '>':
            break
          inc closePos
        if closePos + 2 < html.len:
          pos = closePos + 3
        else:
          pos = html.len
        continue

      # 2. DOCTYPE / <!...> / <?...?>
      if pos + 1 < html.len and (html[pos + 1] == '!' or html[pos + 1] == '?'):
        var endPos = pos + 2
        while endPos < html.len and html[endPos] != '>':
          inc endPos
        pos = if endPos < html.len: endPos + 1 else: html.len
        continue

      # 3. Closing tag </tag>
      if pos + 1 < html.len and html[pos + 1] == '/':
        var idx = pos + 2
        while idx < html.len and isSpaceChar(html[idx]):
          inc idx
        let nameStart = idx
        while idx < html.len and html[idx] != '>' and not isSpaceChar(html[idx]):
          inc idx
        let closeTag = htmlToLowerAscii(html[nameStart ..< idx])
        if closeTag == "script" and not allowJs:
          return resErr[HtmlDoc]("Zero-JS policy violation: <script> tag is forbidden")
        while idx < html.len and html[idx] != '>':
          inc idx
        pos = if idx < html.len: idx + 1 else: html.len

        if closeTag.len > 0:
          # Pop stack back to matching tag
          var matchPos = -1
          for sIdx in countdown(stack.len - 1, 1):
            if doc.nodes[stack[sIdx]].tag == closeTag:
              matchPos = sIdx
              break
          if matchPos > 0:
            stack.setLen(matchPos)
        continue

      # 4. Opening tag <tag ...>
      var idx = pos + 1
      if idx >= html.len or isSpaceChar(html[idx]) or html[idx] == '>' or html[idx] == '<':
        # Literal stray '<' as text
        let curParent = stack[^1]
        let txtIdx = doc.nodes.len
        doc.nodes.add(HtmlNode(kind: hnkText, text: "<", parent: curParent, children: @[]))
        doc.nodes[curParent].children.add(txtIdx)
        inc pos
        continue

      let tagStart = idx
      while idx < html.len and not isSpaceChar(html[idx]) and html[idx] != '>' and html[idx] != '/':
        inc idx
      let tagName = htmlToLowerAscii(html[tagStart ..< idx])
      if tagName.len == 0:
        inc pos
        continue
      if tagName == "script" and not allowJs:
        return resErr[HtmlDoc]("Zero-JS policy violation: <script> tag is forbidden")

      var node = HtmlNode(
        kind: hnkElement,
        tag: tagName,
        id: "",
        classes: @[],
        attrs: @[],
        text: "",
        parent: stack[^1],
        children: @[]
      )

      var selfClosing = false
      while idx < html.len:
        while idx < html.len and isSpaceChar(html[idx]):
          inc idx
        if idx >= html.len:
          break
        if html[idx] == '>':
          inc idx
          break
        if html[idx] == '/' and idx + 1 < html.len and html[idx + 1] == '>':
          selfClosing = true
          idx += 2
          break
        if html[idx] == '/':
          inc idx
          continue

        let attrStart = idx
        while idx < html.len and html[idx] != '=' and html[idx] != '>' and html[idx] != '/' and not isSpaceChar(html[idx]):
          inc idx
        let attrName = htmlToLowerAscii(html[attrStart ..< idx])
        if attrName.len == 0:
          inc idx
          continue
        if isForbiddenEventAttr(attrName):
          return resErr[HtmlDoc]("Zero-JS policy violation: inline event attribute '" & attrName & "' is forbidden")

        var attrVal = ""
        while idx < html.len and isSpaceChar(html[idx]):
          inc idx
        if idx < html.len and html[idx] == '=':
          inc idx
          while idx < html.len and isSpaceChar(html[idx]):
            inc idx
          if idx < html.len and (html[idx] == '"' or html[idx] == '\''):
            let quote = html[idx]
            inc idx
            let valStart = idx
            while idx < html.len and html[idx] != quote:
              inc idx
            attrVal = decodeHtmlEntities(html[valStart ..< idx])
            if idx < html.len and html[idx] == quote:
              inc idx
          else:
            let valStart = idx
            while idx < html.len and not isSpaceChar(html[idx]) and html[idx] != '>':
              if html[idx] == '/' and idx + 1 < html.len and html[idx + 1] == '>':
                break
              inc idx
            attrVal = decodeHtmlEntities(html[valStart ..< idx])

        if (attrName == "href" or attrName == "src" or attrName == "action" or
            attrName == "formaction" or attrName == "xlink:href") and isJavascriptUrl(attrVal):
          return resErr[HtmlDoc]("Zero-JS policy violation: javascript: URI in '" & attrName & "' is forbidden")

        node.attrs.add(HtmlAttr(name: attrName, value: attrVal))
        if attrName == "id":
          node.id = attrVal
        elif attrName == "class":
          node.classes = htmlSplitWhitespace(attrVal)

      pos = idx
      let curParent = stack[^1]
      let nodeIdx = doc.nodes.len
      doc.nodes.add(node)
      doc.nodes[curParent].children.add(nodeIdx)

      if tagName == "script":
        if doc.nodes[nodeIdx].getAttr("src").isSome():
          return resErr[HtmlDoc]("Zig-Explicitness violation: external <script src=...> is forbidden; use inline <script>")
        var capsVal = ""
        let capsOpt = doc.nodes[nodeIdx].getAttr("data-caps")
        if capsOpt.isSome():
          capsVal = capsOpt.get()
        if not selfClosing:
          let jsStart = pos
          var jsEnd = pos
          while jsEnd < html.len:
            if html[jsEnd] == '<' and htmlStartsWithIgnoreCase(html, "</script", jsEnd):
              break
            inc jsEnd
          let jsChunk = htmlStripAscii(html[jsStart ..< jsEnd])
          if jsChunk.len > 0:
            doc.scripts.add(HtmlScriptBlock(code: jsChunk, caps: capsVal))
          pos = jsEnd
          if pos < html.len:
            while pos < html.len and html[pos] != '>':
              inc pos
            if pos < html.len and html[pos] == '>':
              inc pos
        continue

      if tagName == "style" and not selfClosing:
        # Capture raw CSS until </style>
        let cssStart = pos
        var cssEnd = pos
        while cssEnd < html.len:
          if html[cssEnd] == '<' and htmlStartsWithIgnoreCase(html, "</style", cssEnd):
            break
          inc cssEnd
        let cssChunk = htmlStripAscii(html[cssStart ..< cssEnd])
        if cssChunk.len > 0:
          if doc.embeddedCss.len > 0:
            doc.embeddedCss.add('\n')
          doc.embeddedCss.add(cssChunk)
        pos = cssEnd
        if pos < html.len:
          while pos < html.len and html[pos] != '>':
            inc pos
          if pos < html.len and html[pos] == '>':
            inc pos
        continue

      if tagName == "textarea" and not selfClosing:
        # HTML5 RCDATA: capture text until </textarea> and decode entities
        let taStart = pos
        var taEnd = pos
        while taEnd < html.len:
          if html[taEnd] == '<' and htmlStartsWithIgnoreCase(html, "</textarea", taEnd):
            break
          inc taEnd
        let decodedTa = decodeHtmlEntities(html[taStart ..< taEnd])
        if decodedTa.len > 0:
          let txtIdx = doc.nodes.len
          doc.nodes.add(HtmlNode(
            kind: hnkText,
            text: decodedTa,
            parent: nodeIdx,
            children: @[]
          ))
          doc.nodes[nodeIdx].children.add(txtIdx)
        pos = taEnd
        if pos < html.len:
          while pos < html.len and html[pos] != '>':
            inc pos
          if pos < html.len and html[pos] == '>':
            inc pos
        continue

      if not selfClosing and not containsTag(HtmlVoidTags, tagName):
        # Bound open-element stack depth to prevent depth-bomb stack/memory blowup
        if stack.len < MaxHtmlNestingDepth:
          stack.add(nodeIdx)
    else:
      let textStart = pos
      while pos < html.len and html[pos] != '<':
        inc pos
      let collapsed = collapseHtmlWhitespace(html[textStart ..< pos])
      let decoded = decodeHtmlEntities(collapsed)
      if htmlStripAscii(decoded).len > 0:
        let curParent = stack[^1]
        let txtIdx = doc.nodes.len
        doc.nodes.add(HtmlNode(
          kind: hnkText,
          text: decoded,
          parent: curParent,
          children: @[]
        ))
        doc.nodes[curParent].children.add(txtIdx)

  resOk(doc)
