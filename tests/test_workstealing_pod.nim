import corex/workstealing

# Non-POD must NOT compile
static:
  doAssert not compiles(initWorkStealDeque[string](64)),
    "WorkStealDeque[string] must not compile (non-POD)"

# POD must compile
var dq = initWorkStealDeque[int](64)
doAssert dq.capacity == 64

# Job must compile (used in ThreadPool)
var jq = initWorkStealDeque[Job](64)
doAssert jq.capacity == 64

echo "[PASS] POD constraint verified"
