proc escapeStack(): ptr int {.raises: [].} =
  var localVal = 77
  return addr localVal

discard escapeStack()
