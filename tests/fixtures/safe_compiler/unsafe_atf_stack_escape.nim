proc smuggleStackEscape() {.raises: [].} =
  {.emit: """
    int localVar = 9;
    return &localVar;
  """.}

smuggleStackEscape()
