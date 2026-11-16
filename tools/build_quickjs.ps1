$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$JsDir = Join-Path $Root "src\nimui\js"
$VendorDir = Join-Path $JsDir "vendor"
$ObjDir = Join-Path $JsDir ".obj"
$OutLib = Join-Path $JsDir "libquickjs.a"

$NimCmd = Get-Command nim -ErrorAction SilentlyContinue
$MingwBin = $null
if ($NimCmd) {
    $NimRoot = Split-Path -Parent (Split-Path -Parent $NimCmd.Source)
    $Candidate = Join-Path $NimRoot "dist\mingw64\bin"
    if (Test-Path $Candidate) {
        $MingwBin = $Candidate
    }
}

function Resolve-BuildTool {
    param(
        [string]$ToolName
    )
    if ($MingwBin) {
        $PreferredPath = Join-Path $MingwBin "$ToolName.exe"
        if (Test-Path $PreferredPath) {
            return $PreferredPath
        }
    }
    $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    throw "Required build tool '$ToolName' was not found relative to nim.exe (dist\mingw64\bin) or in PATH. Install MinGW-W64 GCC or add '$ToolName' to PATH before running tools/build_quickjs.ps1."
}

$Gcc = Resolve-BuildTool -ToolName "gcc"
$Ar = Resolve-BuildTool -ToolName "ar"

New-Item -ItemType Directory -Force -Path $ObjDir | Out-Null

$Version = (Get-Content (Join-Path $VendorDir "VERSION") -Raw).Trim()

$CFlags = @(
    "-O2",
    "-fwrapv",
    "-D_GNU_SOURCE",
    "-D__USE_MINGW_ANSI_STDIO",
    "-DCONFIG_VERSION=\`"$Version\`"",
    "-Wno-array-bounds",
    "-Wno-format-truncation",
    "-Wno-unused-parameter",
    "-Wno-sign-compare",
    "-Wno-implicit-fallthrough"
)

$Sources = @(
    (Join-Path $VendorDir "quickjs.c"),
    (Join-Path $VendorDir "libregexp.c"),
    (Join-Path $VendorDir "libunicode.c"),
    (Join-Path $VendorDir "cutils.c"),
    (Join-Path $VendorDir "dtoa.c"),
    (Join-Path $JsDir "qjs_bridge.c")
)

$Objs = @()
foreach ($src in $Sources) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $obj = Join-Path $ObjDir "$name.o"
    Write-Host "Compiling $name.c ..."
    & $Gcc @CFlags -I $VendorDir -I $JsDir -c $src -o $obj
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile $src"
    }
    $Objs += $obj
}

if (Test-Path $OutLib) { Remove-Item -Force $OutLib }
Write-Host "Archiving $OutLib ..."
& $Ar rcs $OutLib @Objs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to archive $OutLib"
}

Remove-Item -Recurse -Force $ObjDir
Write-Host "Built $OutLib cleanly."
