proc rawPtrCast() {.raises: [].} =
  {.emit: """
    int val = 42;
    int readVal = *(int*)(&val);
    (void)readVal;
  """.}

rawPtrCast()
