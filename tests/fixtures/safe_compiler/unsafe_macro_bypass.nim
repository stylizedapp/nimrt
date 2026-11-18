import std/macros

macro evilCast(x: untyped): untyped =
  quote do:
    cast[uint](`x`)

proc main() =
  let a = 42
  echo evilCast(a)

main()
