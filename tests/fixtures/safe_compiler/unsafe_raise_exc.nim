proc failWithExc(): int =
  raise newException(ValueError, "unhandled boom")

echo failWithExc()
