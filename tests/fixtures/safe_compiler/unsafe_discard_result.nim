type
  Result[T, E] = object
    isOk: bool
    val: T
    err: E

proc makeResult(x: int): Result[int, string] {.raises: [].} =
  Result[int, string](isOk: true, val: x, err: "")

proc main() {.raises: [].} =
  discard makeResult(42)

main()
