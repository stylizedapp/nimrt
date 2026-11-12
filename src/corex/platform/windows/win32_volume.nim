## corex/platform/windows/win32_volume — Low-Level Win32 Volume & USN Journal Access
##
## Provides direct volume handle acquisition (`\\.\C:`) and FSCTL IOCTL queries
## for querying NTFS USN Journal metadata and raw volume cluster geometry.

import std/widestrs
import ../../result
import ../../memory
import ../../adt
import ./win32_fs

when defined(windows):
  type
    VolumeHandle* = object
      handle*: pointer
      drive*: char
      clusterSize*: int
      isOpen*: bool

    READ_USN_JOURNAL_DATA_V0* = object
      StartUsn*: USN
      ReasonMask*: DWORD
      ReturnOnlyOnClose*: DWORD
      Timeout*: uint64
      BytesToWaitFor*: uint64
      UsnJournalID*: uint64
      minMajorVersion*: uint16
      maxMajorVersion*: uint16

    READ_USN_JOURNAL_DATA_V1* = READ_USN_JOURNAL_DATA_V0

  template MinMajorVersion*(d: READ_USN_JOURNAL_DATA_V0): uint16 = d.minMajorVersion
  template `MinMajorVersion=`*(d: var READ_USN_JOURNAL_DATA_V0, val: uint16) = d.minMajorVersion = val
  template MaxMajorVersion*(d: READ_USN_JOURNAL_DATA_V0): uint16 = d.maxMajorVersion
  template `MaxMajorVersion=`*(d: var READ_USN_JOURNAL_DATA_V0, val: uint16) = d.maxMajorVersion = val

  const
    GENERIC_READ_VOL* = 0x80000000'u32
    FILE_SHARE_RW* = 0x03'u32
    OPEN_EXISTING_VOL* = 3'u32
    FSCTL_READ_USN_JOURNAL* = 0x000900BB'u32
    FSCTL_QUERY_USN_JOURNAL_V* = 0x000900F4'u32

  proc createFileW(
    lpFileName: WideCString,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: pointer,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: pointer
  ): HANDLE {.stdcall, dynlib: "kernel32", importc: "CreateFileW", sideEffect.}

  proc closeHandle(hObject: HANDLE): BOOL {.stdcall, dynlib: "kernel32", importc: "CloseHandle", sideEffect.}

  proc deviceIoControl(
    hDevice: HANDLE,
    dwIoControlCode: DWORD,
    lpInBuffer: pointer,
    nInBufferSize: DWORD,
    lpOutBuffer: pointer,
    nOutBufferSize: DWORD,
    lpBytesReturned: ptr DWORD,
    lpOverlapped: pointer
  ): BOOL {.stdcall, dynlib: "kernel32", importc: "DeviceIoControl", sideEffect.}

  proc getLastError(): DWORD {.stdcall, dynlib: "kernel32", importc: "GetLastError", sideEffect.}

  proc closeVolume*(v: var VolumeHandle) {.raises: [].} =
    if v.isOpen and v.handle != INVALID_HANDLE_VALUE and not v.handle.isNil:
      discard closeHandle(v.handle)
    v.handle = INVALID_HANDLE_VALUE
    v.isOpen = false
    v.drive = '\0'
    v.clusterSize = 0

  proc `=destroy`*(v: var VolumeHandle) {.raises: [].} =
    closeVolume(v)

  proc `=wasMoved`*(v: var VolumeHandle) {.inline, raises: [].} =
    v.handle = INVALID_HANDLE_VALUE
    v.isOpen = false
    v.drive = '\0'
    v.clusterSize = 0

  proc `=sink`*(dest: var VolumeHandle, src: VolumeHandle) {.raises: [].} =
    if dest.handle != src.handle:
      closeVolume(dest)
    dest.handle = src.handle
    dest.drive = src.drive
    dest.clusterSize = src.clusterSize
    dest.isOpen = src.isOpen

  proc `=copy`*(dest: var VolumeHandle, src: VolumeHandle) {.error: "VolumeHandle cannot be copied; use move semantics".}

  proc openVolume*(drive: char): Result[VolumeHandle, IOError] {.raises: [].} =
    ## Opens raw volume handle `\\.\<drive>:` for reading metadata and queries cluster geometry.
    let path = "\\\\.\\" & $drive & ":"
    let wPath = newWideCString(path)
    let hVol = createFileW(
      wPath,
      GENERIC_READ_VOL,
      FILE_SHARE_RW,
      nil,
      OPEN_EXISTING_VOL,
      0,
      nil
    )

    if hVol == INVALID_HANDLE_VALUE or hVol.isNil:
      let errCode = getLastError()
      let msg = if errCode == 5'u32:
        "Failed to open volume '" & path & "': Administrative privileges required to open volume for USN Journal reading (Win32 error 5: Access is denied)"
      else:
        "Failed to open volume '" & path & "': Win32 error " & $errCode
      return err[VolumeHandle, IOError](IOError(msg: msg))

    let geomRes = win32GetClusterGeometry($drive & ":\\")
    let cSize = if geomRes.isOk: geomRes.get.clusterSize else: 4096

    ok[VolumeHandle, IOError](VolumeHandle(
      handle: hVol,
      drive: drive,
      clusterSize: cSize,
      isOpen: true
    ))

  proc queryUsnJournal*(v: VolumeHandle): Result[USN_JOURNAL_DATA_V0, IOError] {.raises: [].} =
    ## Queries NTFS USN Journal metadata via FSCTL_QUERY_USN_JOURNAL.
    if not v.isOpen or v.handle == INVALID_HANDLE_VALUE or v.handle.isNil:
      return err[USN_JOURNAL_DATA_V0, IOError](IOError(msg: "queryUsnJournal: Volume is not open"))

    var usnData: USN_JOURNAL_DATA_V0
    var bytesReturned: DWORD = 0
    let ret = deviceIoControl(
      v.handle,
      FSCTL_QUERY_USN_JOURNAL_V,
      nil,
      0,
      addr usnData,
      DWORD(sizeof(USN_JOURNAL_DATA_V0)),
      addr bytesReturned,
      nil
    )

    if ret == 0:
      let errCode = getLastError()
      return err[USN_JOURNAL_DATA_V0, IOError](IOError(msg: "FSCTL_QUERY_USN_JOURNAL failed: Win32 error " & $errCode))

    ok[USN_JOURNAL_DATA_V0, IOError](usnData)

  proc readUsnJournal*(
    v: VolumeHandle,
    startUsn: USN,
    reasonMask: uint32 = 0xFFFFFFFF'u32,
    buffer: var openArray[byte]
  ): Result[int, IOError] {.raises: [].} =
    ## Reads USN Journal change records via FSCTL_READ_USN_JOURNAL starting from `startUsn`.
    ## Returns the number of bytes populated into `buffer`.
    if not v.isOpen or v.handle == INVALID_HANDLE_VALUE or v.handle.isNil:
      return err[int, IOError](IOError(msg: "readUsnJournal: Volume is not open"))

    if buffer.len == 0:
      return err[int, IOError](IOError(msg: "readUsnJournal: Buffer is empty"))

    var readData: READ_USN_JOURNAL_DATA_V0
    readData.StartUsn = startUsn
    readData.ReasonMask = reasonMask
    readData.ReturnOnlyOnClose = 0'u32
    readData.Timeout = 0'u64
    readData.BytesToWaitFor = 0'u64
    readData.UsnJournalID = 0'u64
    readData.minMajorVersion = 2'u16
    readData.maxMajorVersion = 2'u16

    var bytesReturned: DWORD = 0
    var ret = deviceIoControl(
      v.handle,
      FSCTL_READ_USN_JOURNAL,
      addr readData,
      DWORD(sizeof(READ_USN_JOURNAL_DATA_V0)),
      addr buffer[0],
      DWORD(buffer.len),
      addr bytesReturned,
      nil
    )

    # Fallback to 40-byte V0 if 48-byte V1 structure is rejected
    if ret == 0:
      let firstErr = getLastError()
      if firstErr == 87'u32: # ERROR_INVALID_PARAMETER
        ret = deviceIoControl(
          v.handle,
          FSCTL_READ_USN_JOURNAL,
          addr readData,
          40'u32, # sizeof V0 without min/max major version
          addr buffer[0],
          DWORD(buffer.len),
          addr bytesReturned,
          nil
        )

    if ret == 0:
      let errCode = getLastError()
      return err[int, IOError](IOError(msg: "FSCTL_READ_USN_JOURNAL failed: Win32 error " & $errCode))

    ok[int, IOError](int(bytesReturned))

else:
  type
    VolumeHandle* = object
      handle*: pointer
      drive*: char
      clusterSize*: int
      isOpen*: bool

    READ_USN_JOURNAL_DATA_V0* = object
      StartUsn*: USN
      ReasonMask*: DWORD
      ReturnOnlyOnClose*: DWORD
      Timeout*: uint64
      BytesToWaitFor*: uint64
      UsnJournalID*: uint64
      minMajorVersion*: uint16
      maxMajorVersion*: uint16

    READ_USN_JOURNAL_DATA_V1* = READ_USN_JOURNAL_DATA_V0

  const
    FSCTL_READ_USN_JOURNAL* = 0x000900BB'u32

  proc openVolume*(drive: char): Result[VolumeHandle, IOError] =
    err[VolumeHandle, IOError](IOError(msg: "Volume operations only supported on Windows"))

  proc queryUsnJournal*(v: VolumeHandle): Result[USN_JOURNAL_DATA_V0, IOError] =
    err[USN_JOURNAL_DATA_V0, IOError](IOError(msg: "USN Journal only supported on Windows"))

  proc readUsnJournal*(
    v: VolumeHandle,
    startUsn: USN,
    reasonMask: uint32 = 0xFFFFFFFF'u32,
    buffer: var openArray[byte]
  ): Result[int, IOError] =
    err[int, IOError](IOError(msg: "USN Journal only supported on Windows"))

  proc closeVolume*(v: var VolumeHandle) = discard
