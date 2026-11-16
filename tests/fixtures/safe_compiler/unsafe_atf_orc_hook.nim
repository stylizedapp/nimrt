type
  BadHookObj = object
    handle: int

proc `=destroy`(x: BadHookObj) =
  {.emit: """
    void* p = (void*)0;
    free(p);
  """.}

proc useHook() {.raises: [].} =
  var obj = BadHookObj(handle: 1)
  discard obj.handle

useHook()
