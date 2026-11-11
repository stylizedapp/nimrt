## apps/mini-browser/src/css_match.nim
## CSS selector matching (Level 0: Type selectors only)
import corex
import ./html
import ./css

proc matches*(node: Node, selector: Span[byte]): bool {.inline, raises: [].} =
  ## Level 0 selector matching: only type selectors (e.g. h1, body, p, div).
  ## Class (.foo) and ID (#bar) selectors do not match in Level 0.
  ## Matching is case-insensitive.
  if node.kind != nkElement:
    return false
  if node.tag.len == 0 or selector.len == 0:
    return false
  # If selector starts with '.' or '#', it's a class or id selector -> does not match
  if selector.data[0] == byte('.') or selector.data[0] == byte('#'):
    return false
  if node.tag.len != selector.len:
    return false
  for i in 0 ..< node.tag.len:
    var c1 = node.tag.data[i]
    var c2 = selector.data[i]
    if c1 >= byte('A') and c1 <= byte('Z'): c1 = c1 + 32'u8
    if c2 >= byte('A') and c2 <= byte('Z'): c2 = c2 + 32'u8
    if c1 != c2: return false
  return true

proc matches*(node: Node, selector: string): bool {.inline, raises: [].} =
  if selector.len == 0:
    var empty: array[0, byte]
    matches(node, toByteSpan(empty))
  else:
    matches(node, toByteSpan(selector))

proc matches*(node: Node, rule: Rule): bool {.inline, raises: [].} =
  matches(node, rule.selector)
