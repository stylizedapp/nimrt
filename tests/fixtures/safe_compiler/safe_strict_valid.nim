type
  Result[T, E] = object
    isOk: bool
    val: T
    err: E

proc makeOk(x: int): Result[int, string] {.raises: [].} =
  Result[int, string](isOk: true, val: x, err: "")

proc main() {.raises: [].} =
  let r = makeOk(42)
  doAssert r.isOk
  echo "SAFE_STRICT_OK:", r.val

main()
