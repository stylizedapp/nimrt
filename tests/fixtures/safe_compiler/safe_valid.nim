import corex/result
import corex/adt
import corex/allocators
import corex/memory

proc safeDivide(a, b: int): Result[int, string] {.raises: [].} =
  if b == 0:
    return err[int, string]("division by zero")
  ok[int, string](a div b)

proc sumPair(a, b: int): int {.raises: [].} =
  a + b

proc runSafe(): Result[int, string] {.raises: [].} =
  let alloc = heapAllocator()
  let box = owned(40, alloc)
  let divRes = ?safeDivide(box[], 2)
  let opt = some(sumPair(divRes, 22))
  if opt.isSome():
    return ok[int, string](opt.getOr(0))
  err[int, string]("unreachable")

proc main() {.raises: [].} =
  let r = runSafe()
  doAssert r.isOk()
  var rr = r
  echo "SAFE_VALID_OK:", rr.getOr(0)

main()
