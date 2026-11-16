$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$JsDir = Join-Path $Root "src\nimui\js"
$VendorDir = Join-Path $JsDir "vendor"
$ObjDir = Join-Path $JsDir ".obj"
$OutLib = Join-Path $JsDir "libquickjs.a"

New-Item -ItemType Directory -Force -Path $ObjDir | Out-Null

$Version = (Get-Content (Join-Path $VendorDir "VERSION") -Raw).Trim()
$Gcc = "C:\nim\dist\mingw64\bin\gcc.exe"
$Ar = "C:\nim\dist\mingw64\bin\ar.exe"
if (-not (Test-Path $Gcc)) { $Gcc = "gcc" }
if (-not (Test-Path $Ar)) { $Ar = "ar" }

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
