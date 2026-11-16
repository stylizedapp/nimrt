proc smuggledC() {.raises: [].} =
  {.emit: """
    char buf[4];
    strcpy(buf, "bad");
    void* raw_p = malloc(16);
    free(raw_p);
  """.}

smuggledC()
