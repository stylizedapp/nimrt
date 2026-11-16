{.push checks: off.}
proc uncheckedIndex(a: seq[int]; i: int): int {.raises: [].} =
  a[i]
{.pop.}

proc main() {.raises: [].} =
  echo uncheckedIndex(@[1, 2, 3], 1)

main()
