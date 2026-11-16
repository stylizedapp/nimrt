proc smuggleEmit() {.raises: [].} =
  {.emit: "/* forbidden inline C */".}

smuggleEmit()
