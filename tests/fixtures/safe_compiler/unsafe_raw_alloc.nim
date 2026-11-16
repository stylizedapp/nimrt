proc leakMem() {.raises: [].} =
  discard alloc(64)

leakMem()
