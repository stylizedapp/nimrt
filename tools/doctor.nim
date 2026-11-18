## tools/doctor.nim — First-Run Environment & Toolchain Diagnostic Tool
##
## Checks:
## - Nim compiler (>= 2.0.0) & Nimble
## - MinGW-W64 GCC & ar (bundled with Nim or in PATH)
## - Vulkan 1.1+ loader (vulkan-1.dll / libvulkan.so.1) & GPU physical devices
## - QuickJS static library (src/nimui/js/libquickjs.a) & vendored sources
## - System fonts required by FontAtlas (Segoe UI, Segoe UI Symbol, Consolas, CJK fallback)
## - Workspace write permissions & elevation status
## - Cache & build artifact status (nimcache/, bin/)
##
## Usage:
##   nimble doctor
##   nim c -r tools/doctor.nim [--json]

import std/[os, osproc, strutils, strformat, json, dynlib]

type
  CheckStatus = enum
    csOk = "OK"
    csWarn = "WARN"
    csFail = "FAIL"
    csInfo = "INFO"

  CheckResult = object
    name: string
    status: CheckStatus
    detail: string
    fix: string

var results: seq[CheckResult] = @[]

proc addResult(name: string, status: CheckStatus, detail: string, fix: string = "") =
  results.add(CheckResult(name: name, status: status, detail: detail, fix: fix))

proc firstLine(s: string): string =
  for line in s.splitLines():
    let t = line.strip()
    if t.len > 0:
      return t
  ""

proc runCmdVersion(exe: string, args: openArray[string]): tuple[ok: bool, output: string] =
  try:
    let res = execCmdEx(quoteShellCommand(@[exe] & @args))
    (res.exitCode == 0, res.output.strip())
  except CatchableError as e:
    (false, e.msg)

proc parseNimVersion(verLine: string): tuple[major, minor, patch: int] =
  # Expected: "Nim Compiler Version 2.2.12 [Windows: amd64]"
  for tok in verLine.split(' '):
    let parts = tok.split('.')
    if parts.len == 3:
      try:
        return (parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2]))
      except ValueError:
        discard
  (0, 0, 0)

proc checkNim() =
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    addResult(
      "Nim compiler",
      csFail,
      "nim executable not found in PATH",
      "Install Nim >= 2.0.0 (recommended: 2.2.12 via choosenim or https://nim-lang.org/install.html) and add it to PATH."
    )
    return

  let (ok, outp) = runCmdVersion(nimExe, ["--version"])
  if not ok:
    addResult("Nim compiler", csFail, "Found at " & nimExe & " but `nim --version` failed", "Reinstall Nim >= 2.0.0.")
    return

  let line = firstLine(outp)
  let (maj, min, pat) = parseNimVersion(line)
  if maj < 2:
    addResult(
      "Nim compiler",
      csFail,
      &"{line} ({nimExe}) — requires Nim >= 2.0.0",
      "Upgrade Nim to >= 2.0.0 (recommended: 2.2.12)."
    )
  else:
    addResult("Nim compiler", csOk, &"{maj}.{min}.{pat} ({nimExe})")

proc checkNimble() =
  let nimbleExe = findExe("nimble")
  if nimbleExe.len == 0:
    addResult(
      "Nimble",
      csFail,
      "nimble executable not found in PATH",
      "Install Nimble (included with standard Nim distributions) and add it to PATH."
    )
    return
  let (ok, outp) = runCmdVersion(nimbleExe, ["--version"])
  if not ok:
    addResult("Nimble", csWarn, &"Found at {nimbleExe} but `nimble --version` failed", "Verify Nim installation.")
  else:
    addResult("Nimble", csOk, &"{firstLine(outp)} ({nimbleExe})")

proc resolveMingwTool(toolName: string): string =
  let nimExe = findExe("nim")
  if nimExe.len > 0:
    let nimRoot = nimExe.parentDir().parentDir()
    let bundled = nimRoot / "dist" / "mingw64" / "bin" / (toolName & (when defined(windows): ".exe" else: ""))
    if fileExists(bundled):
      return bundled
  findExe(toolName)

proc checkGccAndAr() =
  let gccExe = resolveMingwTool("gcc")
  if gccExe.len == 0:
    addResult(
      "GCC / MinGW-W64",
      csFail,
      "gcc not found in Nim's dist/mingw64/bin or PATH",
      "Install MinGW-W64 GCC (e.g. via Nim installer or MSYS2) and ensure gcc is in PATH or <nim>/dist/mingw64/bin."
    )
  else:
    let (ok, outp) = runCmdVersion(gccExe, ["--version"])
    if ok:
      addResult("GCC / MinGW-W64", csOk, &"{firstLine(outp)} ({gccExe})")
    else:
      addResult("GCC / MinGW-W64", csFail, &"Found {gccExe} but failed to execute", "Check MinGW-W64 installation.")

  let arExe = resolveMingwTool("ar")
  if arExe.len == 0:
    addResult(
      "Archiver (ar)",
      csFail,
      "ar not found in Nim's dist/mingw64/bin or PATH",
      "Required for building libquickjs.a. Install MinGW-W64 binutils."
    )
  else:
    addResult("Archiver (ar)", csOk, arExe)

# Minimal Vulkan FFI types for doctor diagnostics (no dependency on src/nimui/gpu)
type
  VkResult = int32
  VkInstance = pointer
  VkPhysicalDevice = pointer

  VkApplicationInfo = object
    sType: uint32
    pNext: pointer
    pApplicationName: cstring
    applicationVersion: uint32
    pEngineName: cstring
    engineVersion: uint32
    apiVersion: uint32

  VkInstanceCreateInfo = object
    sType: uint32
    pNext: pointer
    flags: uint32
    pApplicationInfo: ptr VkApplicationInfo
    enabledLayerCount: uint32
    ppEnabledLayerNames: pointer
    enabledExtensionCount: uint32
    ppEnabledExtensionNames: pointer

  VkPhysicalDeviceProperties = object
    apiVersion: uint32
    driverVersion: uint32
    vendorID: uint32
    deviceID: uint32
    deviceType: uint32
    deviceName: array[256, char]
    pipelineCacheUUID: array[16, uint8]
    limitsPad: array[512, byte]
    sparsePad: array[64, byte]

proc vkApiVerStr(v: uint32): string =
  let maj = (v shr 22) and 0x7F'u32
  let min = (v shr 12) and 0x3FF'u32
  let pat = v and 0xFFF'u32
  &"{maj}.{min}.{pat}"

proc checkVulkan() =
  when defined(windows):
    const libName = "vulkan-1.dll"
  elif defined(macosx):
    const libName = "libvulkan.1.dylib"
  else:
    const libName = "libvulkan.so.1"

  let lib = loadLib(libName)
  if lib == nil:
    addResult(
      "Vulkan loader",
      csWarn,
      &"{libName} not found — interactive GPU rendering unavailable (headless software rasterizer still works)",
      "Install or update your GPU vendor driver (AMD/NVIDIA/Intel) or Vulkan Runtime."
    )
    return
  defer: unloadLib(lib)

  type
    PFN_vkEnumerateInstanceVersion = proc(pApiVersion: ptr uint32): VkResult {.stdcall.}
    PFN_vkCreateInstance = proc(pCreateInfo: ptr VkInstanceCreateInfo, pAllocator: pointer, pInstance: ptr VkInstance): VkResult {.stdcall.}
    PFN_vkDestroyInstance = proc(instance: VkInstance, pAllocator: pointer) {.stdcall.}
    PFN_vkEnumeratePhysicalDevices = proc(instance: VkInstance, pPhysicalDeviceCount: ptr uint32, pPhysicalDevices: ptr VkPhysicalDevice): VkResult {.stdcall.}
    PFN_vkGetPhysicalDeviceProperties = proc(physicalDevice: VkPhysicalDevice, pProperties: ptr VkPhysicalDeviceProperties) {.stdcall.}

  let fnEnumVer = cast[PFN_vkEnumerateInstanceVersion](symAddr(lib, "vkEnumerateInstanceVersion"))
  let fnCreateInst = cast[PFN_vkCreateInstance](symAddr(lib, "vkCreateInstance"))
  let fnDestroyInst = cast[PFN_vkDestroyInstance](symAddr(lib, "vkDestroyInstance"))
  let fnEnumDevs = cast[PFN_vkEnumeratePhysicalDevices](symAddr(lib, "vkEnumeratePhysicalDevices"))
  let fnGetProps = cast[PFN_vkGetPhysicalDeviceProperties](symAddr(lib, "vkGetPhysicalDeviceProperties"))

  var loaderVerStr = "1.0.x"
  if fnEnumVer != nil:
    var ver: uint32 = 0
    if fnEnumVer(addr ver) == 0:
      loaderVerStr = vkApiVerStr(ver)

  if fnCreateInst == nil or fnDestroyInst == nil or fnEnumDevs == nil or fnGetProps == nil:
    addResult("Vulkan loader", csWarn, &"{libName} loaded (loader {loaderVerStr}), but core symbols missing", "Reinstall Vulkan Runtime / GPU driver.")
    return

  var appInfo = VkApplicationInfo(
    sType: 0'u32,
    pApplicationName: "nim_ecosystem_doctor",
    applicationVersion: 1'u32,
    pEngineName: "nimui",
    engineVersion: 1'u32,
    apiVersion: (1'u32 shl 22) or (1'u32 shl 12) # Vulkan 1.1
  )
  var instInfo = VkInstanceCreateInfo(
    sType: 1'u32,
    pApplicationInfo: addr appInfo
  )
  var inst: VkInstance = nil
  let res = fnCreateInst(addr instInfo, nil, addr inst)
  if res != 0 or inst == nil:
    addResult(
      "Vulkan driver",
      csWarn,
      &"{libName} present (loader {loaderVerStr}), but vkCreateInstance failed (code {res}); headless software fallback available",
      "Update GPU drivers if you need interactive Vulkan rendering."
    )
    return
  defer: fnDestroyInst(inst, nil)

  var devCount: uint32 = 0
  discard fnEnumDevs(inst, addr devCount, nil)
  if devCount == 0:
    addResult(
      "Vulkan driver",
      csWarn,
      &"Loader {loaderVerStr} OK, 0 Vulkan physical devices found (headless/VM environment)",
      "Install GPU drivers for hardware acceleration; headless software rasterizer works without a GPU."
    )
    return

  var devs = newSeq[VkPhysicalDevice](int(devCount))
  discard fnEnumDevs(inst, addr devCount, addr devs[0])
  var props: VkPhysicalDeviceProperties
  fnGetProps(devs[0], addr props)
  var devName = ""
  for ch in props.deviceName:
    if ch == '\0': break
    devName.add(ch)
  let devApi = vkApiVerStr(props.apiVersion)
  let maj = (props.apiVersion shr 22) and 0x7F'u32
  let min = (props.apiVersion shr 12) and 0x3FF'u32
  if maj < 1 or (maj == 1 and min < 1):
    addResult(
      "Vulkan driver",
      csWarn,
      &"GPU '{devName}' supports Vulkan {devApi} (< 1.1 required)",
      "Update GPU driver to support Vulkan 1.1+."
    )
  else:
    addResult("Vulkan driver", csOk, &"Loader {loaderVerStr}, Device '{devName}', API {devApi}")

proc checkGlslang() =
  let glsl = findExe("glslangValidator")
  if glsl.len > 0:
    addResult("glslangValidator", csOk, glsl)
  else:
    addResult(
      "glslangValidator (optional)",
      csInfo,
      "Not installed (optional: precompiled .spv and src/nimui/gpu/shaders.nim are checked in)",
      "Only needed if modifying GLSL shaders under tools/shaders/."
    )

proc checkQuickJs() =
  let vendorVerPath = "src/nimui/js/vendor/VERSION"
  let libPath = "src/nimui/js/libquickjs.a"
  let vendorVer = if fileExists(vendorVerPath): readFile(vendorVerPath).strip() else: "missing"
  if not fileExists(vendorVerPath):
    addResult("QuickJS vendor", csFail, "src/nimui/js/vendor/VERSION missing", "Verify repository checkout is complete.")
    return

  if fileExists(libPath):
    let szKb = getFileSize(libPath) div 1024
    addResult("QuickJS static lib", csOk, &"src/nimui/js/libquickjs.a ({szKb} KiB, vendor {vendorVer})")
  else:
    addResult(
      "QuickJS static lib",
      csWarn,
      &"src/nimui/js/libquickjs.a not yet built (vendor {vendorVer} present)",
      "Run `nimble build_quickjs` (or `nimble studio/demo/gallery`, which auto-builds it on first run)."
    )

proc checkFonts() =
  when defined(windows):
    var winDir = getEnv("WINDIR")
    if winDir.len == 0: winDir = r"C:\Windows"
    let fontsDir = winDir / "Fonts"
    let requiredFonts = ["segoeui.ttf", "consola.ttf"]
    let fallbackFonts = ["seguisym.ttf", "msyh.ttc", "malgun.ttf"]

    var missingReq: seq[string] = @[]
    for f in requiredFonts:
      if not fileExists(fontsDir / f):
        missingReq.add(f)

    var foundFallback = 0
    for f in fallbackFonts:
      if fileExists(fontsDir / f):
        inc(foundFallback)

    if missingReq.len > 0:
      addResult(
        "System fonts",
        csWarn,
        &"Missing {missingReq.join(\", \")} in {fontsDir}",
        "Ensure standard Windows Segoe UI / Consolas fonts are installed."
      )
    else:
      addResult("System fonts", csOk, &"{fontsDir} (Segoe UI, Consolas, {foundFallback}/{fallbackFonts.len} Unicode/CJK fallbacks)")
  else:
    addResult("System fonts", csInfo, "Font check is Windows GDI specific; skipping on non-Windows host.")

when defined(windows):
  proc OpenProcessToken(ProcessHandle: pointer, DesiredAccess: uint32, TokenHandle: ptr pointer): int32 {.stdcall, dynlib: "advapi32.dll", importc: "OpenProcessToken".}
  proc GetTokenInformation(TokenHandle: pointer, TokenInformationClass: uint32, TokenInformation: pointer, TokenInformationLength: uint32, ReturnLength: ptr uint32): int32 {.stdcall, dynlib: "advapi32.dll", importc: "GetTokenInformation".}
  proc GetCurrentProcess(): pointer {.stdcall, dynlib: "kernel32.dll", importc: "GetCurrentProcess".}
  proc CloseHandle(hObject: pointer): int32 {.stdcall, dynlib: "kernel32.dll", importc: "CloseHandle".}

  proc isElevated(): bool =
    var token: pointer = nil
    if OpenProcessToken(GetCurrentProcess(), 0x0008'u32, addr token) == 0:
      return false
    defer: discard CloseHandle(token)
    var elevation: uint32 = 0
    var retLen: uint32 = 0
    if GetTokenInformation(token, 20'u32, addr elevation, uint32(sizeof(elevation)), addr retLen) != 0:
      return elevation != 0'u32
    false

proc checkPermissions() =
  let probeDirs = [".", "bin", "nimcache", "benchmarks/results"]
  var failedDirs: seq[string] = @[]
  for d in probeDirs:
    try:
      if not dirExists(d):
        createDir(d)
      let probe = d / ".doctor_write_probe.tmp"
      writeFile(probe, "ok")
      removeFile(probe)
    except CatchableError:
      failedDirs.add(d)

  if failedDirs.len > 0:
    addResult(
      "Workspace permissions",
      csFail,
      &"Cannot write to: {failedDirs.join(\", \")}",
      "Check directory permissions or move workspace to a writable user path."
    )
  else:
    when defined(windows):
      let elevStr = if isElevated(): "elevated (Admin)" else: "standard user (OK for all UI/bench/tests; Admin only needed for raw \\\\.\\C: MFT scans)"
      addResult("Workspace permissions", csOk, &"Writable (. / bin / nimcache / benchmarks/results), {elevStr}")
    else:
      addResult("Workspace permissions", csOk, "Writable (. / bin / nimcache / benchmarks/results)")

proc checkCache() =
  if dirExists("nimcache"):
    var fileCount = 0
    var totalBytes: int64 = 0
    for p in walkDirRec("nimcache"):
      inc(fileCount)
      try:
        totalBytes += getFileSize(p)
      except CatchableError:
        discard
    let mb = float(totalBytes) / (1024.0 * 1024.0)
    addResult("Build cache (nimcache)", csOk, &"{fileCount} files, {mb:.1f} MiB (clean with `Remove-Item -Recurse -Force nimcache` if needed)")
  else:
    addResult("Build cache (nimcache)", csInfo, "nimcache/ not present yet (will be created on first build)")

  if dirExists("src/nimui/js/.obj"):
    addResult("QuickJS temp .obj", csWarn, "Stale src/nimui/js/.obj directory present", "Safe to delete or re-run `nimble build_quickjs`.")

proc main() =
  var asJson = false
  for arg in commandLineParams():
    if arg == "--json":
      asJson = true

  checkNim()
  checkNimble()
  checkGccAndAr()
  checkVulkan()
  checkGlslang()
  checkQuickJs()
  checkFonts()
  checkPermissions()
  checkCache()

  var okCount, warnCount, failCount = 0
  for r in results:
    case r.status
    of csOk: inc(okCount)
    of csWarn: inc(warnCount)
    of csFail: inc(failCount)
    of csInfo: discard

  if asJson:
    var arr = newJArray()
    for r in results:
      arr.add(%*{
        "name": r.name,
        "status": $r.status,
        "detail": r.detail,
        "fix": r.fix
      })
    let doc = %*{
      "summary": {"ok": okCount, "warn": warnCount, "fail": failCount},
      "checks": arr
    }
    echo pretty(doc)
  else:
    echo "================================================================================"
    echo "  Nim Ecosystem Doctor — Environment & First-Run Diagnostics"
    echo "================================================================================"
    for r in results:
      let tag = "[" & $r.status & "]"
      echo &"{tag:<7} {r.name:<28} {r.detail}"
      if r.fix.len > 0 and r.status in {csWarn, csFail}:
        echo &"        -> Fix: {r.fix}"
    echo "--------------------------------------------------------------------------------"
    echo &"Summary: {okCount} OK, {warnCount} WARN, {failCount} FAIL"
    if failCount == 0:
      echo "Ready! Quickstart: `nimble studio` | `nimble demo` | `nimble gallery` | `nimble bench_canonical`"

  if failCount > 0:
    quit(1)

main()
