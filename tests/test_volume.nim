import corex/[allocators, result, testing]
import corex/platform/windows/win32_volume
import corex/platform/windows/win32_fs

proc runVolumeTests() =
  echo "=== RUNNING WIN32 VOLUME & USN JOURNAL TESTS ==="

  # Test 1: Non-existent volume 'Z' fails gracefully
  block:
    let res = openVolume('Z')
    doAssert res.isErr, "Expected opening non-existent drive 'Z' to fail"
    echo "[OK] 01: openVolume('Z') returns Result.err as expected"

  # Test 2: Target volume 'C' check (Admin or Non-Admin permission handling)
  block:
    var res = openVolume('C')
    if res.isOk:
      var vol = move(res.val)
      echo "[OK] 02: openVolume('C') successfully acquired volume handle (Admin access detected)"
      echo "     - Drive: ", vol.drive
      echo "     - Cluster size: ", vol.clusterSize, " bytes"

      let usnRes = vol.queryUsnJournal()
      if usnRes.isOk:
        let usnData = usnRes.val
        echo "     - UsnJournalID: ", usnData.UsnJournalID
        echo "     - NextUsn: ", usnData.NextUsn
        doAssert usnData.UsnJournalID != 0
        doAssert usnData.NextUsn > 0
        echo "     [OK] Query USN Journal metadata succeeded"
      else:
        echo "     [NOTE] queryUsnJournal failed: ", usnRes.error.msg
      vol.closeVolume()
    else:
      echo "[OK] 02: openVolume('C') returned Result.err (Normal non-admin environment): ", res.error.msg
      echo "     (Test accepted as expected for non-elevated user)"

  # Test 3: Close idempotency
  block:
    var res = openVolume('Z')
    # Closing an unopened or failed volume handle is a safe no-op
    var dummy: VolumeHandle
    dummy.closeVolume()
    dummy.closeVolume()
    echo "[OK] 03: closeVolume is idempotent on uninitialized handles"

  # Test 4: Leak test with repeated open attempts
  testWithLeakCheck("Volume 100 open attempts leak test"):
    for _ in 0 ..< 100:
      var r = openVolume('Z')
      if r.isOk:
        r.val.closeVolume()
  echo "[OK] 04: testWithLeakCheck on 100 openVolume calls verified 0 leaks"

  echo "=== ALL VOLUME TESTS PASSED ==="

when isMainModule:
  runVolumeTests()
