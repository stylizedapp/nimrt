## corex/mft — Uniform NTFS Master File Table (MFT) Facade
##
## Provides high-performance MFT record parsing, multi-sector fixup validation,
## runlist extents calculation, and direct volume streaming:
## - Metadata structures: `MftEntry`, `MftDataRun`, `MftStreamStats`
## - Record parsing: `parseMftRecord`, `parseMftBuffer`
## - Fixup restoration: `restoreFixups`
## - Raw volume streaming: `openMftStreamer`, `MftStreamer`
## - Compile-time platform dispatch to `win32_mft` on Windows

when defined(windows):
  import ./platform/windows/win32_mft
  export win32_mft
else:
  import ./result

  const
    MFT_RECORD_SIZE* = 1024
    MFT_SECTOR_SIZE* = 512
    MFT_MAGIC_FILE* = 0x454C4946'u32
    MFT_MAGIC_BAAD* = 0x44414142'u32

    MFT_RECORD_IN_USE* = 0x0001'u16
    MFT_RECORD_IS_DIRECTORY* = 0x0002'u16

  type
    MftParseMode* = enum
      mpmLenient
      mpmStrict

    MftEntry* = object
      frn*: uint64
      parentFrn*: uint64
      baseRecordFrn*: uint64
      linkCount*: uint16
      fileSize*: int64
      sizeOnDisk*: int64
      flags*: uint32
      name*: string
      isDir*: bool
      creationTime*: int64
      modificationTime*: int64
      hasAttrList*: bool
      childFrns*: seq[uint64]

    MftDataRun* = object
      lcn*: int64
      clusterCount*: int64
      isSparse*: bool

    MftStreamStats* = object
      totalRecords*: int64
      activeFiles*: int64
      activeDirs*: int64
      skippedRecords*: int64
      corruptRecords*: int64
      bytesRead*: int64
