var gSharedCounter = 0

proc incGlobal() {.raises: [].} =
  gSharedCounter += 1

incGlobal()
