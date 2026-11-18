proc c_abs(x: cint): cint {.importc: "abs", header: "<stdlib.h>".}

proc main() =
  echo c_abs(-5)

main()
