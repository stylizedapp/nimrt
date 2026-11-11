## corex/result — Zero-overhead Result[T, E], `?` operator, and Zig-style `errdefer`
##
## Brings modern, ergonomic error handling from Rust (`Result`, `?`, `unwrap`)
## and Zig (`errdefer`, triggered strictly upon error returns) to Nim.
##
## Guarantees:
## - Zero overhead: Flat tagged union on stack, fully inlined, raises: []
## - Zero leaks under ARC/ORC
## - Panic-free unless assertive unwrapping is explicitly requested via `unwrap`

import std/macros

type
  ResultDefect* = object of Defect
    ## Fatal assertion failure when unwrapping an Err Result or unwrapErr on an Ok Result.
  UnwrapDefect* = object of ResultDefect
    ## Specific defect for assertive unwrap failures.

  Result*[T, E] = object
    ## Flat tagged union representing either success (`isOk == true`) with value `T`,
    ## or failure (`isOk == false`) with error `E`.
    case isOk*: bool
    of true:
      when T isnot void:
        val*: T
    of false:
      when E isnot void:
        errVal*: E

# =============================================================================
# Constructors
# =============================================================================

proc ok*[T: not void; E](v: sink T): Result[T, E] {.inline, raises: [].} =
  ## Constructs an Ok Result containing value `v`.
  Result[T, E](isOk: true, val: move(v))

proc ok*[T: void; E](): Result[void, E] {.inline, raises: [].} =
  ## Constructs an Ok Result of void type.
  Result[void, E](isOk: true)

proc ok*[E](_: typedesc[void], _: typedesc[E] = void): Result[void, E] {.inline, raises: [].} =
  ## Constructs an Ok Result[void, E] via typedesc arguments.
  Result[void, E](isOk: true)

template ok*[E](r: var Result[void, E]) =
  ## In-place mutation of a Result[void, E] to Ok.
  r = Result[void, E](isOk: true)

proc ok*[T: not void; E](_: typedesc[Result[T, E]], v: sink T): Result[T, E] {.inline, raises: [].} =
  ## Static factory constructor `Result[T, E].ok(val)`.
  Result[T, E](isOk: true, val: move(v))

proc ok*[T: void; E](_: typedesc[Result[T, E]]): Result[void, E] {.inline, raises: [].} =
  ## Static factory constructor `Result[void, E].ok()`.
  Result[void, E](isOk: true)

proc err*[T; E: not void](e: sink E): Result[T, E] {.inline, raises: [].} =
  ## Constructs an Err Result containing error `e`.
  Result[T, E](isOk: false, errVal: move(e))

proc err*[T; E: void](): Result[T, void] {.inline, raises: [].} =
  ## Constructs an Err Result of void error type.
  Result[T, void](isOk: false)

proc err*[T, E](_: typedesc[Result[T, E]], e: sink E): Result[T, E] {.inline, raises: [].} =
  ## Static factory constructor `Result[T, E].err(errVal)`.
  Result[T, E](isOk: false, errVal: move(e))

# =============================================================================
# Predicates and Accessors
# =============================================================================

proc isOk*[T, E](r: Result[T, E]): bool {.inline, raises: [].} =
  ## Returns true if the result is Ok.
  r.isOk

proc isErr*[T, E](r: Result[T, E]): bool {.inline, raises: [].} =
  ## Returns true if the result is Err.
  not r.isOk

proc get*[T, E](r: var Result[T, E]): T {.inline.} =
  ## Moves the inner value out of a var Result. Asserts `r.isOk`.
  doAssert r.isOk, "Attempted to .get() an Err Result"
  when T isnot void:
    move(r.val)

proc get*[T, E](r: sink Result[T, E]): T {.inline.} =
  ## Moves the inner value out of a sink/value Result. Asserts `r.isOk`.
  doAssert r.isOk, "Attempted to .get() an Err Result"
  when T isnot void:
    move(r.val)

proc error*[T, E](r: var Result[T, E]): E {.inline.} =
  ## Moves the inner error value out of a var Result. Asserts `not r.isOk`.
  doAssert not r.isOk, "Attempted to .error() an Ok Result"
  when E isnot void:
    move(r.errVal)

proc error*[T, E](r: sink Result[T, E]): E {.inline.} =
  ## Moves the inner error value out of a sink/value Result. Asserts `not r.isOk`.
  doAssert not r.isOk, "Attempted to .error() an Ok Result"
  when E isnot void:
    move(r.errVal)

proc getOr*[T: not void; E](r: var Result[T, E], defaultVal: sink T): T {.inline, raises: [].} =
  ## Returns the inner value if Ok, otherwise moves `defaultVal`.
  ## For copyable types, returns a copy without modifying `r`.
  ## For move-only types, moves the value out of `r` (destructive extraction).
  if r.isOk:
    when compiles(block: (var x: T = r.val)):
      r.val
    else:
      move(r.val)
  else:
    move(defaultVal)

proc getOr*[T: not void; E](r: sink Result[T, E], defaultVal: sink T): T {.inline, raises: [].} =
  ## Moves and returns the inner value if Ok, otherwise moves `defaultVal`.
  if r.isOk: move(r.val) else: move(defaultVal)

proc getOr*[T: void; E](r: Result[T, E]) {.inline, raises: [].} =
  ## No-op accessor for Result[void, E].
  discard

template getOrElse*[T, E](r: Result[T, E], fallback: untyped): auto =
  ## Lazily returns inner value if Ok, or evaluates fallback expression if Err.
  let res = r
  if res.isOk:
    when T isnot void: res.val
  else:
    fallback

# =============================================================================
# Value Equality and String Representation
# =============================================================================

proc `==`*[T, E](a, b: Result[T, E]): bool {.inline, raises: [].} =
  ## Equality comparison for Result. Required because default system.`==` fails
  ## on variant case objects in Nim.
  if a.isOk != b.isOk:
    return false
  if a.isOk:
    when T is void:
      return true
    else:
      return a.val == b.val
  else:
    when E is void:
      return true
    else:
      return a.errVal == b.errVal

proc `$`*[T, E](r: Result[T, E]): string =
  ## String representation of Result for logging and debugging.
  if r.isOk:
    when T is void:
      "Ok()"
    else:
      "Ok(" & $r.val & ")"
  else:
    when E is void:
      "Err()"
    else:
      "Err(" & $r.errVal & ")"

# =============================================================================
# Assertive Unwrapping (`unwrap` and `unwrapErr`)
# =============================================================================

proc unwrap*[T, E](r: sink Result[T, E], msg: string = ""): T {.inline, raises: [].} =
  ## Extracts the value if Ok (moving it when r is sunk/temporary or copying when lvalue).
  ## Panics with `ResultDefect` if Err.
  if r.isOk:
    when T isnot void:
      return move(r.val)
  else:
    var m = when E isnot void and compiles($r.errVal):
              "Result unwrap failed on Err: " & $r.errVal
            else:
              "Result unwrap failed on Err"
    if msg.len > 0:
      m = msg & " - " & m
    raise (ref UnwrapDefect)(msg: m)

proc unwrap*[T, E](r: var Result[T, E], msg: string = ""): T {.inline, raises: [].} =
  ## Moves the value out if Ok from var. Panics with `ResultDefect` if Err.
  if r.isOk:
    when T isnot void:
      return move(r.val)
  else:
    var m = when E isnot void and compiles($r.errVal):
              "Result unwrap failed on Err: " & $r.errVal
            else:
              "Result unwrap failed on Err"
    if msg.len > 0:
      m = msg & " - " & m
    raise (ref UnwrapDefect)(msg: m)

proc unwrapErr*[T, E](r: sink Result[T, E], msg: string = ""): E {.inline, raises: [].} =
  ## Extracts the error value if Err. Panics with `ResultDefect` if Ok.
  if not r.isOk:
    when E isnot void:
      return move(r.errVal)
  else:
    var m = when T isnot void and compiles($r.val):
              "Result unwrapErr failed on Ok: " & $r.val
            else:
              "Result unwrapErr failed on Ok"
    if msg.len > 0:
      m = msg & " - " & m
    raise (ref UnwrapDefect)(msg: m)

proc unwrapErr*[T, E](r: var Result[T, E], msg: string = ""): E {.inline, raises: [].} =
  ## Moves the error value out if Err from var. Panics with `ResultDefect` if Ok.
  if not r.isOk:
    when E isnot void:
      return move(r.errVal)
  else:
    var m = when T isnot void and compiles($r.val):
              "Result unwrapErr failed on Ok: " & $r.val
            else:
              "Result unwrapErr failed on Ok"
    if msg.len > 0:
      m = msg & " - " & m
    raise (ref UnwrapDefect)(msg: m)

template expect*[T, E](r: Result[T, E], msg: string): auto =
  ## Alias for `unwrap(r, msg)` in Rust style.
  unwrap(r, msg)

template expectErr*[T, E](r: Result[T, E], msg: string): auto =
  ## Alias for `unwrapErr(r, msg)` in Rust style.
  unwrapErr(r, msg)

# =============================================================================
# Monadic Chaining (`map`, `flatMap`, `andThen`, `orElse`, `mapError`)
# =============================================================================

template map*[T, E](r: Result[T, E], f: untyped): auto =
  ## Transforms the contained value via `f` if Ok, returning a new Result.
  ## Supports procs (`r.map(toStr)`), inline closures (`r.map(proc(x): int = ...)`),
  ## and untyped expressions (`r.map(it * 2)`).
  block:
    let res = r
    when T is void:
      when compiles(f()):
        type OutType = typeof(f())
        if res.isOk:
          when OutType is void:
            f()
            ok[void, E]()
          else:
            ok[OutType, E](f())
        else:
          when E is void:
            when OutType is void:
              err[void, void]()
            else:
              err[OutType, void]()
          else:
            when OutType is void:
              err[void, E](res.errVal)
            else:
              err[OutType, E](res.errVal)
      else:
        type OutType = typeof(f)
        if res.isOk:
          when OutType is void:
            f
            ok[void, E]()
          else:
            ok[OutType, E](f)
        else:
          when E is void:
            when OutType is void:
              err[void, void]()
            else:
              err[OutType, void]()
          else:
            when OutType is void:
              err[void, E](res.errVal)
            else:
              err[OutType, E](res.errVal)
    else:
      when compiles(f(res.val)):
        type OutType = typeof(f(res.val))
        if res.isOk:
          when OutType is void:
            f(res.val)
            ok[void, E]()
          else:
            ok[OutType, E](f(res.val))
        else:
          when E is void:
            when OutType is void:
              err[void, void]()
            else:
              err[OutType, void]()
          else:
            when OutType is void:
              err[void, E](res.errVal)
            else:
              err[OutType, E](res.errVal)
      else:
        type OutType = typeof((
          block:
            let it {.inject.} = res.val
            f
        ))
        if res.isOk:
          let it {.inject.} = res.val
          when OutType is void:
            f
            ok[void, E]()
          else:
            ok[OutType, E](f)
        else:
          when E is void:
            when OutType is void:
              err[void, void]()
            else:
              err[OutType, void]()
          else:
            when OutType is void:
              err[void, E](res.errVal)
            else:
              err[OutType, E](res.errVal)

template flatMap*[T, E](r: Result[T, E], f: untyped): auto =
  ## Monadic bind: if Ok, invokes `f` (which returns a Result), otherwise propagates Err.
  block:
    let res = r
    type RetType = typeof((
      when T is void:
        when compiles(f()):
          f()
        else:
          f
      else:
        when compiles(f(res.val)):
          f(res.val)
        else:
          block:
            let it {.inject.} = res.val
            f
    ))
    if res.isOk:
      when T is void:
        when compiles(f()):
          f()
        else:
          f
      else:
        when compiles(f(res.val)):
          f(res.val)
        else:
          block:
            let it {.inject.} = res.val
            f
    else:
      when compiles(RetType(isOk: false, errVal: res.errVal)):
        RetType(isOk: false, errVal: res.errVal)
      else:
        RetType(isOk: false)

template andThen*[T, E](r: Result[T, E], f: untyped): auto =
  ## Alias for `flatMap`.
  flatMap(r, f)

template orElse*[T, E](r: Result[T, E], f: untyped): auto =
  ## Recovers from Err: if Ok, returns inner Ok, otherwise invokes `f` to produce a new Result.
  block:
    let res = r
    type RetType = typeof((
      when E is void:
        when compiles(f()):
          f()
        else:
          f
      else:
        when compiles(f(res.errVal)):
          f(res.errVal)
        else:
          block:
            let it {.inject.} = res.errVal
            f
    ))
    if res.isOk:
      when T is void:
        RetType(isOk: true)
      else:
        RetType(isOk: true, val: res.val)
    else:
      when E is void:
        when compiles(f()):
          f()
        else:
          f
      else:
        when compiles(f(res.errVal)):
          f(res.errVal)
        else:
          block:
            let it {.inject.} = res.errVal
            f

template mapError*[T, E](r: Result[T, E], f: untyped): auto =
  ## Transforms the error value via `f` if Err, preserving Ok value.
  block:
    let res = r
    when E is void:
      when compiles(f()):
        type OutErr = typeof(f())
        if res.isOk:
          when T is void: ok[void, OutErr]()
          else: ok[T, OutErr](res.val)
        else:
          when OutErr is void:
            f()
            err[T, void]()
          else:
            err[T, OutErr](f())
      else:
        type OutErr = typeof(f)
        if res.isOk:
          when T is void: ok[void, OutErr]()
          else: ok[T, OutErr](res.val)
        else:
          when OutErr is void:
            f
            err[T, void]()
          else:
            err[T, OutErr](f)
    else:
      when compiles(f(res.errVal)):
        type OutErr = typeof(f(res.errVal))
        if res.isOk:
          when T is void: ok[void, OutErr]()
          else: ok[T, OutErr](res.val)
        else:
          when OutErr is void:
            f(res.errVal)
            err[T, void]()
          else:
            err[T, OutErr](f(res.errVal))
      else:
        type OutErr = typeof((
          block:
            let it {.inject.} = res.errVal
            f
        ))
        if res.isOk:
          when T is void: ok[void, OutErr]()
          else: ok[T, OutErr](res.val)
        else:
          let it {.inject.} = res.errVal
          when OutErr is void:
            f
            err[T, void]()
          else:
            err[T, OutErr](f)

# Convenient standard aliases matching Nim's sequtils (*It)
template mapIt*[T, E](r: Result[T, E], body: untyped): auto =
  map(r, body)

template flatMapIt*[T, E](r: Result[T, E], body: untyped): auto =
  flatMap(r, body)

template andThenIt*[T, E](r: Result[T, E], body: untyped): auto =
  andThen(r, body)

template orElseIt*[T, E](r: Result[T, E], body: untyped): auto =
  orElse(r, body)

template mapErrorIt*[T, E](r: Result[T, E], body: untyped): auto =
  mapError(r, body)

# =============================================================================
# Early Return Operator `?`
# =============================================================================

template `?`*[T, E](r: Result[T, E]): auto =
  ## Early-return operator in Rust (`?`) and Zig (`try`) style.
  ## If the expression evaluates to Err, immediately returns Err from the current procedure.
  block:
    let res = r
    if not res.isOk:
      when E is void:
        return typeof(result)(isOk: false)
      else:
        when compiles(typeof(result)(isOk: false, errVal: res.errVal)):
          return typeof(result)(isOk: false, errVal: res.errVal)
        else:
          return typeof(result)(isOk: false, errVal: typeof(result.errVal)(res.errVal))
    when T isnot void:
      res.val

# =============================================================================
# Zig-style `errdefer`
# =============================================================================

template errdefer*(cleanupBody: untyped) =
  ## Zig construct: executes `cleanupBody` at scope exit ONLY if the enclosing
  ## procedure finishes with an error (`not isOk(result)`).
  ## Intended for procedure-level scope.
  defer:
    if not isOk(result):
      cleanupBody
