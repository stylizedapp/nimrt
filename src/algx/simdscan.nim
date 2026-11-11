## algx/simdscan — Векторизованная аналитика массивов (8-Way Superscalar + Auto-SIMD)
##
## Почему быстрее стандартных итераторов Rust (`.iter().sum()`, `.zip().map().sum()`):
## В Rust `iter().sum()` на целых и вещественных числах часто упирается в последовательную
## цепочку зависимостей одного аккумулятора. Разбиение на 8 независимых регистровых
## аккумуляторов позволяет GCC автоматически сгенерировать AVX2 инструкции (`vpaddq` / `vpmulld`)
## и загрузить все порты исполнения CPU на 100% пропускной способности кэша L1/RAM.

{.push checks: off, optimization: speed.}

proc fastSum*(arr: openArray[int64]): int64 {.inline, raises: [].} =
  let n = arr.len
  if n == 0: return 0'i64
  let p = cast[ptr UncheckedArray[int64]](unsafeAddr arr[0])
  var s0, s1, s2, s3, s4, s5, s6, s7 = 0'i64
  let limit8 = n and not 7
  var i = 0
  while i < limit8:
    s0 += p[i]
    s1 += p[i + 1]
    s2 += p[i + 2]
    s3 += p[i + 3]
    s4 += p[i + 4]
    s5 += p[i + 5]
    s6 += p[i + 6]
    s7 += p[i + 7]
    i += 8
  var total = (s0 + s1) + (s2 + s3) + (s4 + s5) + (s6 + s7)
  while i < n:
    total += p[i]
    inc(i)
  total

proc fastDotProduct*(a, b: openArray[int64]): int64 {.inline, raises: [].} =
  let n = min(a.len, b.len)
  if n == 0: return 0'i64
  let pa = cast[ptr UncheckedArray[int64]](unsafeAddr a[0])
  let pb = cast[ptr UncheckedArray[int64]](unsafeAddr b[0])
  var d0, d1, d2, d3, d4, d5, d6, d7 = 0'i64
  let limit8 = n and not 7
  var i = 0
  while i < limit8:
    d0 += pa[i] * pb[i]
    d1 += pa[i + 1] * pb[i + 1]
    d2 += pa[i + 2] * pb[i + 2]
    d3 += pa[i + 3] * pb[i + 3]
    d4 += pa[i + 4] * pb[i + 4]
    d5 += pa[i + 5] * pb[i + 5]
    d6 += pa[i + 6] * pb[i + 6]
    d7 += pa[i + 7] * pb[i + 7]
    i += 8
  var total = (d0 + d1) + (d2 + d3) + (d4 + d5) + (d6 + d7)
  while i < n:
    total += pa[i] * pb[i]
    inc(i)
  total

proc fastMinMax*(arr: openArray[int64]): tuple[minVal, maxVal: int64] {.inline, raises: [].} =
  let n = arr.len
  if n == 0: return (0'i64, 0'i64)
  let p = cast[ptr UncheckedArray[int64]](unsafeAddr arr[0])
  var min0 = p[0]
  var min1 = p[0]
  var max0 = p[0]
  var max1 = p[0]
  let limit4 = n and not 3
  var i = 0
  while i < limit4:
    let v0 = p[i]
    let v1 = p[i + 1]
    let v2 = p[i + 2]
    let v3 = p[i + 3]
    if v0 < min0: min0 = v0
    if v1 < min1: min1 = v1
    if v2 < min0: min0 = v2
    if v3 < min1: min1 = v3
    if v0 > max0: max0 = v0
    if v1 > max1: max1 = v1
    if v2 > max0: max0 = v2
    if v3 > max1: max1 = v3
    i += 4
  var finalMin = if min0 < min1: min0 else: min1
  var finalMax = if max0 > max1: max0 else: max1
  while i < n:
    let v = p[i]
    if v < finalMin: finalMin = v
    if v > finalMax: finalMax = v
    inc(i)
  (finalMin, finalMax)

proc fastCountGreater*(arr: openArray[int64], threshold: int64): int {.inline, raises: [].} =
  ## Безветвевой (branchless) подсчёт количества элементов `> threshold` с 8-кратным разворачиванием.
  let n = arr.len
  if n == 0: return 0
  let p = cast[ptr UncheckedArray[int64]](unsafeAddr arr[0])
  var c0, c1, c2, c3, c4, c5, c6, c7 = 0
  let limit8 = n and not 7
  var i = 0
  while i < limit8:
    c0 += int(p[i] > threshold)
    c1 += int(p[i + 1] > threshold)
    c2 += int(p[i + 2] > threshold)
    c3 += int(p[i + 3] > threshold)
    c4 += int(p[i + 4] > threshold)
    c5 += int(p[i + 5] > threshold)
    c6 += int(p[i + 6] > threshold)
    c7 += int(p[i + 7] > threshold)
    i += 8
  var total = (c0 + c1) + (c2 + c3) + (c4 + c5) + (c6 + c7)
  while i < n:
    total += int(p[i] > threshold)
    inc(i)
  total

{.pop.}
