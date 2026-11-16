proc tryRaise(): int {.raises: [].} =
  try:
    raise newException(ValueError, "boom")
  except CatchableError:
    return 0

echo tryRaise()
