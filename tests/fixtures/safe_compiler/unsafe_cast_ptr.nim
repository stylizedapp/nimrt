proc badCast(): int {.raises: [].} =
  var x = 42
  let raw = cast[uint](x)
  int(raw)

echo badCast()
