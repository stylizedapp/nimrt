import corex/result

proc safeGenericAdd[T](a, b: T): Result[T, string] {.raises: [].} =
  ok[T, string](a + b)

proc main() {.raises: [].} =
  let r = safeGenericAdd(20, 22)
  doAssert r.isOk()
  var rr = r
  echo "SAFE_GENERIC_OK:", rr.getOr(0)

main()
