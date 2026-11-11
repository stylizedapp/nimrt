## corex/io — High-Performance Cross-Platform I/O Primitives
##
## Provides:
## - RAII `FileHandle` with deterministic `=destroy` auto-close and zero leaks.
## - 64KB `BufferedReader` minimizing kernel transitions, zero-allocation `readLine`,
##   and zero-copy `peekSpan` binary slicing.
## - 64KB `BufferedWriter` with auto-flush on buffer saturation and `=destroy`.
## - Monadic error handling using `Result[T, IOError]` and `?` operator.

import std/options
import std/widestrs
when defined(posix):
  import std/posix

import ./result
import ./allocators
import ./memory

# =============================================================================
# Platform C Bindings & OS Handle Types
# =============================================================================

when defined(windows):
  type
    RawHandle* = pointer
    LargeInteger {.importc: "LARGE_INTEGER", header: "<windows.h>".} = object
      QuadPart {.importc: "QuadPart".}: int64

  const
    InvalidRawHandle*: RawHandle = cast[pointer](-1)

    GENERIC_READ* = 0x80000000'u32
    GENERIC_WRITE* = 0x40000000'u32
    FILE_SHARE_READ* = 0x00000001'u32
    FILE_SHARE_WRITE* = 0x00000002'u32
    CREATE_ALWAYS* = 2'u32
    OPEN_EXISTING* = 3'u32
    OPEN_ALWAYS* = 4'u32
    FILE_ATTRIBUTE_NORMAL* = 0x00000080'u32
    FILE_BEGIN* = 0'u32
    FILE_CURRENT* = 1'u32
    FILE_END* = 2'u32

  proc winCreateFileW(
    lpFileName: WideCString,
    dwDesiredAccess: uint32,
    dwShareMode: uint32,
    lpSecurityAttributes: pointer,
    dwCreationDisposition: uint32,
    dwFlagsAndAttributes: uint32,
    hTemplateFile: RawHandle
  ): RawHandle {.importc: "CreateFileW", header: "<windows.h>", stdcall.}

  proc winCloseHandle(hObject: RawHandle): int32 {.
    importc: "CloseHandle", header: "<windows.h>", stdcall.}

  proc winReadFile(
    hFile: RawHandle,
    lpBuffer: pointer,
    nNumberOfBytesToRead: uint32,
    lpNumberOfBytesRead: ptr uint32,
    lpOverlapped: pointer
  ): int32 {.importc: "ReadFile", header: "<windows.h>", stdcall.}

  proc winWriteFile(
    hFile: RawHandle,
    lpBuffer: pointer,
    nNumberOfBytesToWrite: uint32,
    lpNumberOfBytesWritten: ptr uint32,
    lpOverlapped: pointer
  ): int32 {.importc: "WriteFile", header: "<windows.h>", stdcall.}

  proc winSetFilePointerEx(
    hFile: RawHandle,
    liDistanceToMove: LargeInteger,
    lpNewFilePointer: ptr LargeInteger,
    dwMoveMethod: uint32
  ): int32 {.importc: "SetFilePointerEx", header: "<windows.h>", stdcall.}

  proc winFlushFileBuffers(hFile: RawHandle): int32 {.
    importc: "FlushFileBuffers", header: "<windows.h>", stdcall.}

  proc winGetLastError(): uint32 {.
    importc: "GetLastError", header: "<windows.h>", stdcall.}

else:
  type RawHandle* = cint
  const InvalidRawHandle*: RawHandle = -1.cint

# =============================================================================
# Public Types & Error Handling
# =============================================================================

const DefaultBufferSize* = 64 * 1024

type
  FileMode* = enum
    fmRead
    fmWrite
    fmReadWrite
    fmAppend

  SeekOrigin* = enum
    soBegin
    soCurrent
    soEnd

  FileHandle* = object
    handle*: RawHandle
    isOpen*: bool

proc `$`*(e: IOError): string {.inline.} =
  if e.msg.len > 0: e.msg else: "I/O error"

proc ioError*(msg: string): IOError {.inline.} =
  IOError(msg: msg)

# =============================================================================
# FileHandle Lifecycle & Operations
# =============================================================================

proc close*(f: var FileHandle): Result[void, IOError] =
  if not f.isOpen:
    return ok[void, IOError]()
  f.isOpen = false
  when defined(windows):
    if f.handle != InvalidRawHandle and f.handle != nil:
      let res = winCloseHandle(f.handle)
      f.handle = InvalidRawHandle
      if res == 0:
        return err[void, IOError](ioError("CloseHandle failed: " & $winGetLastError()))
  else:
    if f.handle >= 0:
      let res = posix.close(f.handle)
      f.handle = InvalidRawHandle
      if res != 0:
        return err[void, IOError](ioError("close failed"))
  ok[void, IOError]()

proc `=destroy`*(f: var FileHandle) =
  if f.isOpen:
    discard f.close()

proc `=copy`*(dest: var FileHandle, src: FileHandle) {.error: "FileHandle cannot be copied; use move semantics".}

proc `=wasMoved`*(f: var FileHandle) {.inline.} =
  f.handle = InvalidRawHandle
  f.isOpen = false

proc `=sink`*(dest: var FileHandle, src: FileHandle) =
  if dest.handle != src.handle:
    `=destroy`(dest)
  dest.handle = src.handle
  dest.isOpen = src.isOpen

proc isOpen*(f: FileHandle): bool {.inline.} = f.isOpen
proc rawHandle*(f: FileHandle): RawHandle {.inline.} = f.handle

# Move-only Result ergonomics for FileHandle
proc ok*[E](v: sink FileHandle): Result[FileHandle, E] {.inline, raises: [].} =
  Result[FileHandle, E](isOk: true, val: move(v))

proc get*[E](r: sink Result[FileHandle, E]): FileHandle {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc get*[E](r: var Result[FileHandle, E]): FileHandle {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc unwrap*[E](r: sink Result[FileHandle, E], msg: string = ""): FileHandle {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result: " & msg
  move(r.val)

proc unwrap*[E](r: var Result[FileHandle, E], msg: string = ""): FileHandle {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result: " & msg
  move(r.val)

proc unwrapErr*[E](r: Result[FileHandle, E]): E {.inline.} =
  doAssert not r.isOk, "Attempted to unwrapErr an Ok Result"
  r.errVal

proc openFile*(path: string, mode: FileMode = fmRead): Result[FileHandle, IOError] =
  when defined(windows):
    var access: uint32 = 0
    var share: uint32 = FILE_SHARE_READ
    var disp: uint32 = OPEN_EXISTING

    case mode
    of fmRead:
      access = GENERIC_READ
      share = FILE_SHARE_READ or FILE_SHARE_WRITE
      disp = OPEN_EXISTING
    of fmWrite:
      access = GENERIC_WRITE
      share = FILE_SHARE_READ or FILE_SHARE_WRITE
      disp = CREATE_ALWAYS
    of fmReadWrite:
      access = GENERIC_READ or GENERIC_WRITE
      share = FILE_SHARE_READ or FILE_SHARE_WRITE
      disp = OPEN_ALWAYS
    of fmAppend:
      access = GENERIC_WRITE
      share = FILE_SHARE_READ or FILE_SHARE_WRITE
      disp = OPEN_ALWAYS

    let widePath = newWideCString(path)
    let h = winCreateFileW(
      widePath,
      access,
      share,
      nil,
      disp,
      FILE_ATTRIBUTE_NORMAL,
      nil
    )
    if h == InvalidRawHandle or h == nil:
      let errCode = winGetLastError()
      return err[FileHandle, IOError](ioError("Failed to open file '" & path & "': error " & $errCode))
    
    var fh = FileHandle(handle: h, isOpen: true)
    if mode == fmAppend:
      var dist: LargeInteger
      dist.QuadPart = 0
      var newPos: LargeInteger
      discard winSetFilePointerEx(h, dist, addr newPos, FILE_END)
    
    ok[IOError](move(fh))
  else:
    var flags: cint = 0
    case mode
    of fmRead: flags = O_RDONLY
    of fmWrite: flags = O_WRONLY or O_CREAT or O_TRUNC
    of fmReadWrite: flags = O_RDWR or O_CREAT
    of fmAppend: flags = O_WRONLY or O_CREAT or O_APPEND

    let fd = posix.open(path.cstring, flags, 0o666.cint)
    if fd < 0:
      return err[FileHandle, IOError](ioError("Failed to open file '" & path & "'"))
    ok[IOError](FileHandle(handle: fd, isOpen: true))

proc write*(f: var FileHandle, data: pointer, size: int): Result[int, IOError] =
  if not f.isOpen: return err[int, IOError](ioError("File is closed"))
  if size <= 0: return ok[int, IOError](0)
  when defined(windows):
    var bytesWritten: uint32 = 0
    let res = winWriteFile(f.handle, data, uint32(size), addr bytesWritten, nil)
    if res == 0:
      return err[int, IOError](ioError("WriteFile failed: error " & $winGetLastError()))
    ok[int, IOError](int(bytesWritten))
  else:
    let res = posix.write(f.handle, data, size)
    if res < 0: return err[int, IOError](ioError("write failed"))
    ok[int, IOError](int(res))

proc write*(f: var FileHandle, s: string): Result[int, IOError] {.inline.} =
  if s.len == 0: return ok[int, IOError](0)
  f.write(unsafeAddr s[0], s.len)

proc write*(f: var FileHandle, data: openArray[byte]): Result[int, IOError] {.inline.} =
  if data.len == 0: return ok[int, IOError](0)
  f.write(unsafeAddr data[0], data.len)

proc read*(f: var FileHandle, buffer: pointer, size: int): Result[int, IOError] =
  if not f.isOpen: return err[int, IOError](ioError("File is closed"))
  if size <= 0: return ok[int, IOError](0)
  when defined(windows):
    var bytesRead: uint32 = 0
    let res = winReadFile(f.handle, buffer, uint32(size), addr bytesRead, nil)
    if res == 0:
      let errCode = winGetLastError()
      if errCode == 38: # ERROR_HANDLE_EOF
        return ok[int, IOError](0)
      return err[int, IOError](ioError("ReadFile failed: error " & $errCode))
    ok[int, IOError](int(bytesRead))
  else:
    let res = posix.read(f.handle, buffer, size)
    if res < 0: return err[int, IOError](ioError("read failed"))
    ok[int, IOError](int(res))

proc read*(f: var FileHandle, buffer: var openArray[byte]): Result[int, IOError] {.inline.} =
  if buffer.len == 0: return ok[int, IOError](0)
  f.read(addr buffer[0], buffer.len)

proc flush*(f: var FileHandle): Result[void, IOError] =
  if not f.isOpen: return err[void, IOError](ioError("File is closed"))
  when defined(windows):
    let res = winFlushFileBuffers(f.handle)
    if res == 0:
      return err[void, IOError](ioError("FlushFileBuffers failed: error " & $winGetLastError()))
    ok[void, IOError]()
  else:
    let res = posix.fsync(f.handle)
    if res != 0: return err[void, IOError](ioError("fsync failed"))
    ok[void, IOError]()

proc seek*(f: var FileHandle, offset: int64, origin: SeekOrigin = soBegin): Result[int64, IOError] =
  if not f.isOpen: return err[int64, IOError](ioError("File is closed"))
  when defined(windows):
    var moveMethod: uint32 = FILE_BEGIN
    case origin
    of soBegin: moveMethod = FILE_BEGIN
    of soCurrent: moveMethod = FILE_CURRENT
    of soEnd: moveMethod = FILE_END

    var dist: LargeInteger
    dist.QuadPart = offset
    var newPos: LargeInteger
    let res = winSetFilePointerEx(f.handle, dist, addr newPos, moveMethod)
    if res == 0:
      return err[int64, IOError](ioError("SetFilePointerEx failed: error " & $winGetLastError()))
    ok[int64, IOError](newPos.QuadPart)
  else:
    var whence: cint = SEEK_SET
    case origin
    of soBegin: whence = SEEK_SET
    of soCurrent: whence = SEEK_CUR
    of soEnd: whence = SEEK_END

    let res = posix.lseek(f.handle, offset, whence)
    if res < 0: return err[int64, IOError](ioError("lseek failed"))
    ok[int64, IOError](res)

# =============================================================================
# BufferedWriter (64KB Auto-Flush on Saturation and =destroy)
# =============================================================================

type
  BufferedWriter* = object
    file*: FileHandle
    buffer*: ptr UncheckedArray[byte]
    capacity*: int
    tail*: int
    alloc*: Allocator

proc flush*(w: var BufferedWriter): Result[void, IOError] =
  if w.tail > 0 and w.file.isOpen:
    var offset = 0
    while offset < w.tail:
      let res = w.file.write(addr w.buffer[offset], w.tail - offset)
      if res.isErr:
        return err[void, IOError](res.error)
      let written = res.get
      if written <= 0:
        return err[void, IOError](ioError("BufferedWriter flush: wrote 0 bytes"))
      offset += written
    w.tail = 0
  w.file.flush()

proc close*(w: var BufferedWriter): Result[void, IOError] =
  let fr = w.flush()
  let cr = w.file.close()
  if fr.isErr: return fr
  cr

proc `=destroy`*(w: var BufferedWriter) =
  if w.tail > 0 and w.file.isOpen:
    discard w.flush()
  if not w.buffer.isNil and w.capacity > 0:
    w.alloc.dealloc(w.buffer, w.capacity)
    w.buffer = nil
    w.capacity = 0
    w.tail = 0

proc `=copy`*(dest: var BufferedWriter, src: BufferedWriter) {.error: "BufferedWriter cannot be copied; use move semantics".}

proc `=wasMoved`*(w: var BufferedWriter) {.inline.} =
  w.buffer = nil
  w.capacity = 0
  w.tail = 0

proc `=sink`*(dest: var BufferedWriter, src: BufferedWriter) =
  if dest.buffer != src.buffer:
    `=destroy`(dest)
  dest.file = src.file
  dest.buffer = src.buffer
  dest.capacity = src.capacity
  dest.tail = src.tail
  dest.alloc = src.alloc

proc ok*[E](v: sink BufferedWriter): Result[BufferedWriter, E] {.inline, raises: [].} =
  Result[BufferedWriter, E](isOk: true, val: move(v))

proc get*[E](r: sink Result[BufferedWriter, E]): BufferedWriter {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc get*[E](r: var Result[BufferedWriter, E]): BufferedWriter {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc unwrap*[E](r: sink Result[BufferedWriter, E], msg: string = ""): BufferedWriter {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result: " & msg
  move(r.val)

proc unwrap*[E](r: var Result[BufferedWriter, E], msg: string = ""): BufferedWriter {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result: " & msg
  move(r.val)

proc unwrapErr*[E](r: Result[BufferedWriter, E]): E {.inline.} =
  doAssert not r.isOk, "Attempted to unwrapErr an Ok Result"
  r.errVal

proc initBufferedWriter*(
  file: sink FileHandle,
  bufferSize: int = DefaultBufferSize,
  alloc: Allocator = defaultHeapAllocator()
): Result[BufferedWriter, IOError] =
  let cap = if bufferSize <= 0: DefaultBufferSize else: bufferSize
  let raw = alloc.rawAlloc(cap, 8)
  if raw.isErr:
    return err[BufferedWriter, IOError](ioError("Failed to allocate BufferedWriter buffer"))
  ok[BufferedWriter, IOError](BufferedWriter(
    file: move(file),
    buffer: cast[ptr UncheckedArray[byte]](raw.get),
    capacity: cap,
    tail: 0,
    alloc: alloc
  ))

proc openBufferedWriter*(
  path: string,
  mode: FileMode = fmWrite,
  bufferSize: int = DefaultBufferSize,
  alloc: Allocator = defaultHeapAllocator()
): Result[BufferedWriter, IOError] =
  var fh = ?openFile(path, mode)
  initBufferedWriter(move(fh), bufferSize, alloc)

proc writeBytes*(w: var BufferedWriter, data: pointer, size: int): Result[int, IOError] =
  if size <= 0: return ok[int, IOError](0)
  var remaining = size
  var srcOffset = 0

  while remaining > 0:
    let space = w.capacity - w.tail
    if space == 0:
      ?w.flush()
    if w.tail == 0 and remaining >= w.capacity:
      # Direct write optimization for large buffers
      let res = w.file.write(cast[pointer](cast[uint](data) + uint(srcOffset)), remaining)
      if res.isErr: return res
      let written = res.get
      srcOffset += written
      remaining -= written
    else:
      let chunk = min(remaining, w.capacity - w.tail)
      copyMem(addr w.buffer[w.tail], cast[pointer](cast[uint](data) + uint(srcOffset)), chunk)
      w.tail += chunk
      srcOffset += chunk
      remaining -= chunk
  ok[int, IOError](size)

proc writeBytes*(w: var BufferedWriter, data: openArray[byte]): Result[int, IOError] {.inline.} =
  if data.len == 0: return ok[int, IOError](0)
  w.writeBytes(unsafeAddr data[0], data.len)

proc write*(w: var BufferedWriter, s: string): Result[int, IOError] {.inline.} =
  if s.len == 0: return ok[int, IOError](0)
  w.writeBytes(unsafeAddr s[0], s.len)

proc writeLine*(w: var BufferedWriter, s: string): Result[void, IOError] =
  if s.len > 0:
    discard ?w.write(s)
  discard ?w.write("\n")
  ok[void, IOError]()

# =============================================================================
# BufferedReader (64KB Syscall Reduction & Zero-Allocation Reading)
# =============================================================================

type
  BufferedReader* = object
    file*: FileHandle
    buffer*: ptr UncheckedArray[byte]
    capacity*: int
    head*: int
    tail*: int
    eof*: bool
    alloc*: Allocator

proc close*(r: var BufferedReader): Result[void, IOError] =
  r.file.close()

proc `=destroy`*(r: var BufferedReader) =
  if not r.buffer.isNil and r.capacity > 0:
    r.alloc.dealloc(r.buffer, r.capacity)
    r.buffer = nil
    r.capacity = 0
    r.head = 0
    r.tail = 0

proc `=copy`*(dest: var BufferedReader, src: BufferedReader) {.error: "BufferedReader cannot be copied; use move semantics".}

proc `=wasMoved`*(r: var BufferedReader) {.inline.} =
  r.buffer = nil
  r.capacity = 0
  r.head = 0
  r.tail = 0
  r.eof = true

proc `=sink`*(dest: var BufferedReader, src: BufferedReader) =
  if dest.buffer != src.buffer:
    `=destroy`(dest)
  dest.file = src.file
  dest.buffer = src.buffer
  dest.capacity = src.capacity
  dest.head = src.head
  dest.tail = src.tail
  dest.eof = src.eof
  dest.alloc = src.alloc

proc ok*[E](v: sink BufferedReader): Result[BufferedReader, E] {.inline, raises: [].} =
  Result[BufferedReader, E](isOk: true, val: move(v))

proc get*[E](r: sink Result[BufferedReader, E]): BufferedReader {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc get*[E](r: var Result[BufferedReader, E]): BufferedReader {.inline.} =
  doAssert r.isOk, "Attempted to .get() an Err Result"
  move(r.val)

proc unwrap*[E](r: sink Result[BufferedReader, E], msg: string = ""): BufferedReader {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result: " & msg
  move(r.val)

proc unwrap*[E](r: var Result[BufferedReader, E], msg: string = ""): BufferedReader {.inline.} =
  doAssert r.isOk, "Attempted to unwrap an Err Result: " & msg
  move(r.val)

proc unwrapErr*[E](r: Result[BufferedReader, E]): E {.inline.} =
  doAssert not r.isOk, "Attempted to unwrapErr an Ok Result"
  r.errVal

proc initBufferedReader*(
  file: sink FileHandle,
  bufferSize: int = DefaultBufferSize,
  alloc: Allocator = defaultHeapAllocator()
): Result[BufferedReader, IOError] =
  let cap = if bufferSize <= 0: DefaultBufferSize else: bufferSize
  let raw = alloc.rawAlloc(cap, 8)
  if raw.isErr:
    return err[BufferedReader, IOError](ioError("Failed to allocate BufferedReader buffer"))
  ok[BufferedReader, IOError](BufferedReader(
    file: move(file),
    buffer: cast[ptr UncheckedArray[byte]](raw.get),
    capacity: cap,
    head: 0,
    tail: 0,
    eof: false,
    alloc: alloc
  ))

proc openBufferedReader*(
  path: string,
  bufferSize: int = DefaultBufferSize,
  alloc: Allocator = defaultHeapAllocator()
): Result[BufferedReader, IOError] =
  var fh = ?openFile(path, fmRead)
  initBufferedReader(move(fh), bufferSize, alloc)

proc available*(r: BufferedReader): int {.inline.} =
  r.tail - r.head

proc fillBuffer(r: var BufferedReader): Result[int, IOError] =
  if r.head < r.tail:
    return ok[int, IOError](r.tail - r.head)
  if r.eof:
    return ok[int, IOError](0)
  r.head = 0
  r.tail = 0
  let readRes = r.file.read(r.buffer, r.capacity)
  if readRes.isErr:
    return readRes
  let n = readRes.get
  if n == 0:
    r.eof = true
    return ok[int, IOError](0)
  r.tail = n
  ok[int, IOError](n)

proc readBytes*(r: var BufferedReader, dest: pointer, size: int): Result[int, IOError] =
  if size <= 0: return ok[int, IOError](0)
  var totalRead = 0
  var remaining = size
  var dstOffset = 0

  while remaining > 0:
    let avail = r.available()
    if avail > 0:
      let chunk = min(remaining, avail)
      copyMem(cast[pointer](cast[uint](dest) + uint(dstOffset)), addr r.buffer[r.head], chunk)
      r.head += chunk
      dstOffset += chunk
      totalRead += chunk
      remaining -= chunk
    else:
      if remaining >= r.capacity:
        # Direct kernel read optimization for large buffers
        let directRes = r.file.read(cast[pointer](cast[uint](dest) + uint(dstOffset)), remaining)
        if directRes.isErr: return directRes
        let n = directRes.get
        if n == 0:
          r.eof = true
          break
        totalRead += n
        break
      else:
        let n = ?r.fillBuffer()
        if n == 0:
          break
  ok[int, IOError](totalRead)

proc readBytes*(r: var BufferedReader, dest: var openArray[byte]): Result[int, IOError] {.inline.} =
  if dest.len == 0: return ok[int, IOError](0)
  r.readBytes(addr dest[0], dest.len)

proc readLine*(r: var BufferedReader, line: var string): Result[bool, IOError] =
  line.setLen(0)
  var foundAny = false

  while true:
    if r.head >= r.tail:
      let n = ?r.fillBuffer()
      if n == 0:
        if foundAny:
          if line.len > 0 and line[^1] == '\r':
            line.setLen(line.len - 1)
          return ok[bool, IOError](true)
        return ok[bool, IOError](false)

    foundAny = true
    var newlineIdx = -1
    for i in r.head ..< r.tail:
      if r.buffer[i] == byte('\n'):
        newlineIdx = i
        break

    if newlineIdx >= 0:
      let chunkLen = newlineIdx - r.head
      if chunkLen > 0:
        let startPos = line.len
        line.setLen(startPos + chunkLen)
        copyMem(addr line[startPos], addr r.buffer[r.head], chunkLen)
      r.head = newlineIdx + 1
      if line.len > 0 and line[^1] == '\r':
        line.setLen(line.len - 1)
      return ok[bool, IOError](true)
    else:
      let chunkLen = r.tail - r.head
      let startPos = line.len
      line.setLen(startPos + chunkLen)
      copyMem(addr line[startPos], addr r.buffer[r.head], chunkLen)
      r.head = r.tail

proc readLine*(r: var BufferedReader): Result[Option[string], IOError] =
  var str = ""
  let hasLine = ?r.readLine(str)
  if hasLine:
    ok[Option[string], IOError](some(str))
  else:
    ok[Option[string], IOError](none(string))

proc readAll*(r: var BufferedReader): Result[string, IOError] =
  var res = ""
  var chunk = newString(8192)
  while true:
    let n = ?r.readBytes(addr chunk[0], 8192)
    if n == 0: break
    res.add(chunk[0 ..< n])
  ok[string, IOError](res)

proc peekSpan*(r: var BufferedReader): ByteSpan =
  if r.head >= r.tail:
    span[byte]()
  else:
    span(cast[ptr byte](addr r.buffer[r.head]), r.tail - r.head)

proc consume*(r: var BufferedReader, n: int) =
  r.head = min(r.tail, r.head + max(0, n))
