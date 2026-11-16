proc takeLocalAddr(): int {.raises: [].} =
  var localVal = 77
  discard addr localVal
  localVal

echo takeLocalAddr()
