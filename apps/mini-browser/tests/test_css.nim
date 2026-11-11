## apps/mini-browser/tests/test_css.nim
## Comprehensive unit tests for CSS Tokenizer (30+ tests) and Level 0 Parser (20+ tests)
import corex/[testing, allocators, memory, result, containers]
import ../src/[css, html]

# =============================================================================
# Tokenizer Tests (30+ tests)
# =============================================================================

testWithLeakCheck("T01: empty input"):
  let tokens = tokenizeCss("", testAlloc).unwrap()
  assert tokens.len == 1
  assert tokens[0].kind == ctEof

testWithLeakCheck("T02: whitespace only"):
  let tokens = tokenizeCss("   \t\r\n   ", testAlloc).unwrap()
  assert tokens.len == 1
  assert tokens[0].kind == ctEof

testWithLeakCheck("T03: single ident"):
  let tokens = tokenizeCss("h1", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctIdent
  assert tokens[0].text == "h1"

testWithLeakCheck("T04: dashed ident"):
  let tokens = tokenizeCss("background-color", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctIdent
  assert tokens[0].text == "background-color"

testWithLeakCheck("T05: underscore ident"):
  let tokens = tokenizeCss("_custom_var", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctIdent
  assert tokens[0].text == "_custom_var"

testWithLeakCheck("T06: uppercase ident"):
  let tokens = tokenizeCss("DISPLAY", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctIdent
  assert tokens[0].text == "DISPLAY"

testWithLeakCheck("T07: braces"):
  let tokens = tokenizeCss("{}", testAlloc).unwrap()
  assert tokens.len == 3
  assert tokens[0].kind == ctLBrace
  assert tokens[1].kind == ctRBrace

testWithLeakCheck("T08: colon and semicolon"):
  let tokens = tokenizeCss(":;", testAlloc).unwrap()
  assert tokens.len == 3
  assert tokens[0].kind == ctColon
  assert tokens[1].kind == ctSemicolon

testWithLeakCheck("T09: comma"):
  let tokens = tokenizeCss(",", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctComma

testWithLeakCheck("T10: 6-digit hex hash"):
  let tokens = tokenizeCss("#ff0000", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctHash
  assert tokens[0].text == "#ff0000"

testWithLeakCheck("T11: 3-digit hex hash"):
  let tokens = tokenizeCss("#fff", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctHash
  assert tokens[0].text == "#fff"

testWithLeakCheck("T12: 8-digit hex hash"):
  let tokens = tokenizeCss("#11223344", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctHash
  assert tokens[0].text == "#11223344"

testWithLeakCheck("T13: integer number"):
  let tokens = tokenizeCss("42", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctNumber
  assert tokens[0].text == "42"

testWithLeakCheck("T14: float number"):
  let tokens = tokenizeCss("3.14", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctNumber
  assert tokens[0].text == "3.14"

testWithLeakCheck("T15: zero number"):
  let tokens = tokenizeCss("0", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctNumber
  assert tokens[0].text == "0"

testWithLeakCheck("T16: dimension px"):
  let tokens = tokenizeCss("24px", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctDimension
  assert tokens[0].text == "24px"

testWithLeakCheck("T17: dimension float px"):
  let tokens = tokenizeCss("1.5px", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctDimension
  assert tokens[0].text == "1.5px"

testWithLeakCheck("T18: dimension percentage"):
  let tokens = tokenizeCss("100%", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctDimension
  assert tokens[0].text == "100%"

testWithLeakCheck("T19: dimension em"):
  let tokens = tokenizeCss("2em", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctDimension
  assert tokens[0].text == "2em"

testWithLeakCheck("T20: comment ignored"):
  let tokens = tokenizeCss("/* comment */ h1", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctIdent
  assert tokens[0].text == "h1"

testWithLeakCheck("T21: multiple comments"):
  let tokens = tokenizeCss("/* c1 */ h1 /* c2 */ { /* c3 */ }", testAlloc).unwrap()
  assert tokens.len == 4
  assert tokens[0].kind == ctIdent
  assert tokens[1].kind == ctLBrace
  assert tokens[2].kind == ctRBrace

testWithLeakCheck("T22: multi-line comment"):
  let tokens = tokenizeCss("/* line 1\nline 2\nline 3 */ p", testAlloc).unwrap()
  assert tokens.len == 2
  assert tokens[0].kind == ctIdent
  assert tokens[0].text == "p"

testWithLeakCheck("T23: declaration token stream"):
  let tokens = tokenizeCss("color: red;", testAlloc).unwrap()
  assert tokens.len == 5
  assert tokens[0].kind == ctIdent and tokens[0].text == "color"
  assert tokens[1].kind == ctColon
  assert tokens[2].kind == ctIdent and tokens[2].text == "red"
  assert tokens[3].kind == ctSemicolon

testWithLeakCheck("T24: rule token stream"):
  let tokens = tokenizeCss("h1 { color: red; }", testAlloc).unwrap()
  assert tokens.len == 8
  assert tokens[0].kind == ctIdent and tokens[0].text == "h1"
  assert tokens[1].kind == ctLBrace
  assert tokens[2].kind == ctIdent and tokens[2].text == "color"
  assert tokens[3].kind == ctColon
  assert tokens[4].kind == ctIdent and tokens[4].text == "red"
  assert tokens[5].kind == ctSemicolon
  assert tokens[6].kind == ctRBrace
  assert tokens[7].kind == ctEof

testWithLeakCheck("T25: multiple selectors comma"):
  let tokens = tokenizeCss("h1, h2, h3", testAlloc).unwrap()
  assert tokens.len == 6
  assert tokens[0].kind == ctIdent
  assert tokens[1].kind == ctComma
  assert tokens[2].kind == ctIdent
  assert tokens[3].kind == ctComma
  assert tokens[4].kind == ctIdent

testWithLeakCheck("T26: consecutive punctuation"):
  let tokens = tokenizeCss("{;}:", testAlloc).unwrap()
  assert tokens.len == 5
  assert tokens[0].kind == ctLBrace
  assert tokens[1].kind == ctSemicolon
  assert tokens[2].kind == ctRBrace
  assert tokens[3].kind == ctColon

testWithLeakCheck("T27: hash without hex error"):
  let res = tokenizeCss("#", testAlloc)
  assert res.isErr

testWithLeakCheck("T28: unclosed comment error"):
  let res = tokenizeCss("/* unclosed comment", testAlloc)
  assert res.isErr

testWithLeakCheck("T29: unexpected char error"):
  let res = tokenizeCss("h1 @ media", testAlloc)
  assert res.isErr

testWithLeakCheck("T30: offsets tracking"):
  let tokens = tokenizeCss("   h1  {", testAlloc).unwrap()
  assert tokens[0].offset == 3
  assert tokens[1].offset == 7

testWithLeakCheck("T31: numbers and dimensions mixed"):
  let tokens = tokenizeCss("10 20px 30.5 40%", testAlloc).unwrap()
  assert tokens[0].kind == ctNumber
  assert tokens[1].kind == ctDimension
  assert tokens[2].kind == ctNumber
  assert tokens[3].kind == ctDimension

testWithLeakCheck("T32: ident with numbers"):
  let tokens = tokenizeCss("h1 h2 h3 h4 h5 h6", testAlloc).unwrap()
  for i in 0 ..< 6:
    assert tokens[i].kind == ctIdent

# =============================================================================
# Parser Level 0 Tests (20+ tests)
# =============================================================================

testWithLeakCheck("P01: empty stylesheet"):
  let sheet = parseCss("", testAlloc).unwrap()
  assert sheet.rules.len == 0

testWithLeakCheck("P02: single rule with one declaration"):
  let sheet = parseCss("h1 { color: red }", testAlloc).unwrap()
  assert sheet.rules.len == 1
  let r = sheet.rules[0]
  assert r.selector == "h1"
  assert r.declarations.len == 1
  assert r.declarations[0].property == "color"
  assert r.declarations[0].value == "red"

testWithLeakCheck("P03: trailing semicolon"):
  let sheet = parseCss("h1 { color: red; }", testAlloc).unwrap()
  assert sheet.rules.len == 1
  assert sheet.rules[0].declarations.len == 1
  assert sheet.rules[0].declarations[0].property == "color"
  assert sheet.rules[0].declarations[0].value == "red"

testWithLeakCheck("P04: multiple declarations"):
  let sheet = parseCss("h1 { color: #ff0000; background-color: #ffffff; }", testAlloc).unwrap()
  assert sheet.rules.len == 1
  let r = sheet.rules[0]
  assert r.declarations.len == 2
  assert r.declarations[0].property == "color"
  assert r.declarations[0].value == "#ff0000"
  assert r.declarations[1].property == "background-color"
  assert r.declarations[1].value == "#ffffff"

testWithLeakCheck("P05: multiple rules"):
  let sheet = parseCss("body { color: black } div { display: none }", testAlloc).unwrap()
  assert sheet.rules.len == 2
  assert sheet.rules[0].selector == "body"
  assert sheet.rules[0].declarations[0].property == "color"
  assert sheet.rules[0].declarations[0].value == "black"
  assert sheet.rules[1].selector == "div"
  assert sheet.rules[1].declarations[0].property == "display"
  assert sheet.rules[1].declarations[0].value == "none"

testWithLeakCheck("P06: rule with empty declarations"):
  let sheet = parseCss("h1 {}", testAlloc).unwrap()
  assert sheet.rules.len == 1
  assert sheet.rules[0].selector == "h1"
  assert sheet.rules[0].declarations.len == 0

testWithLeakCheck("P07: dimension value"):
  let sheet = parseCss("h1 { height: 48px; width: 600px; }", testAlloc).unwrap()
  assert sheet.rules[0].declarations.len == 2
  assert sheet.rules[0].declarations[0].property == "height"
  assert sheet.rules[0].declarations[0].value == "48px"
  assert sheet.rules[0].declarations[1].property == "width"
  assert sheet.rules[0].declarations[1].value == "600px"

testWithLeakCheck("P08: comments in rules"):
  let sheet = parseCss("/* header */ h1 /* tag */ { /* color */ color: red; }", testAlloc).unwrap()
  assert sheet.rules.len == 1
  assert sheet.rules[0].selector == "h1"
  assert sheet.rules[0].declarations[0].property == "color"
  assert sheet.rules[0].declarations[0].value == "red"

testWithLeakCheck("P09: comma-separated selectors"):
  let sheet = parseCss("h1, h2 { color: blue }", testAlloc).unwrap()
  assert sheet.rules.len == 2
  assert sheet.rules[0].selector == "h1"
  assert sheet.rules[0].declarations[0].value == "blue"
  assert sheet.rules[1].selector == "h2"
  assert sheet.rules[1].declarations[0].value == "blue"

testWithLeakCheck("P10: whitespace freedom"):
  let sheet = parseCss("   p   {   color   :   green   ;   }   ", testAlloc).unwrap()
  assert sheet.rules.len == 1
  assert sheet.rules[0].selector == "p"
  assert sheet.rules[0].declarations[0].property == "color"
  assert sheet.rules[0].declarations[0].value == "green"

testWithLeakCheck("P11: display none declaration"):
  let sheet = parseCss("div { display: none }", testAlloc).unwrap()
  assert sheet.rules[0].declarations[0].property == "display"
  assert sheet.rules[0].declarations[0].value == "none"

testWithLeakCheck("P12: three rules sequence"):
  let sheet = parseCss("h1 { color: red } p { color: blue } span { color: green }", testAlloc).unwrap()
  assert sheet.rules.len == 3
  assert sheet.rules[0].selector == "h1"
  assert sheet.rules[1].selector == "p"
  assert sheet.rules[2].selector == "span"

testWithLeakCheck("P13: parseCss from string overload"):
  let sheet = parseCss("h1 { color: red }", testAlloc).unwrap()
  assert sheet.rules.len == 1

testWithLeakCheck("P14: error on missing left brace"):
  let res = parseCss("h1 color: red }", testAlloc)
  assert res.isErr

testWithLeakCheck("P15: error on missing right brace"):
  let res = parseCss("h1 { color: red", testAlloc)
  assert res.isErr

testWithLeakCheck("P16: error on missing colon"):
  let res = parseCss("h1 { color red; }", testAlloc)
  assert res.isErr

testWithLeakCheck("P17: error on missing value"):
  let res = parseCss("h1 { color: ; }", testAlloc)
  assert res.isErr

testWithLeakCheck("P18: error on selector expecting ident"):
  let res = parseCss("{ color: red }", testAlloc)
  assert res.isErr

testWithLeakCheck("P19: error on dangling comma in selector"):
  let res = parseCss("h1, { color: red }", testAlloc)
  assert res.isErr

testWithLeakCheck("P20: uppercase properties and values preserved"):
  let sheet = parseCss("H1 { COLOR: RED }", testAlloc).unwrap()
  assert sheet.rules[0].selector == "H1"
  assert sheet.rules[0].declarations[0].property == "COLOR"
  assert sheet.rules[0].declarations[0].value == "RED"

testWithLeakCheck("P21: multiple semicolons allowed"):
  let sheet = parseCss("h1 { color: red;; font-size: 16px; }", testAlloc).unwrap()
  assert sheet.rules.len == 1

echo "[PASS] test_css: all 32 tokenizer + 21 parser tests passed (53 total)"
