proc badGenericCast[T](x: T): uint {.raises: [].} =
  cast[uint](x)

proc uninstantiatedGenericPtr[T](p: ptr T): int {.raises: [].} =
  if p == nil: 0 else: 1

proc main() {.raises: [].} =
  echo badGenericCast(42)

main()
