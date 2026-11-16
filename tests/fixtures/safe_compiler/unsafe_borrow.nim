{.experimental: "views".}

proc borrowAndMutate() {.raises: [].} =
  var x = 10
  let view: lent int = x
  x = 99
  echo view

borrowAndMutate()
