proc bump(p: ptr UncheckedArray[byte]): uint =
  cast[uint](p) + 4'u

proc main() =
  echo "pointer arithmetic should be rejected"

main()
