## src/nimui/html_css.nim
##
## Pure-Nim HTML5 + CSS3 Engine (Zero-JS) for NimUI — Facade Module.
##
## Re-exports:
## - `nimui/html/types`: AST/CSS types, constants, exception-free string/number helpers
## - `nimui/html/parser`: HTML5 parser, entity decoder, Zero-JS policy enforcement
## - `nimui/html/cascade`: CSS3 color/gradient/shadow/media/var() parser & cascade
## - `nimui/html/compiler`: `HtmlBindingRegistry` & reactive DOM-to-`UiTree` mounter

import ./html/types
import ./html/parser
import ./html/cascade
import ./html/compiler

export types
export parser
export cascade
export compiler
