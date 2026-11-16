template trustedUnsafe() {.pragma.}

proc lowLevelApproved(): int {.trustedUnsafe, raises: [].} =
  var x = 21
  let p = addr x
  let casted = cast[int](p[])
  casted * 2

proc main() {.raises: [].} =
  let val = lowLevelApproved()
  doAssert val == 42
  block trustedUnsafe:
    var y = 10
    let py = addr y
    doAssert py[] == 10
  echo "TRUSTED_UNSAFE_OK:", val

main()
