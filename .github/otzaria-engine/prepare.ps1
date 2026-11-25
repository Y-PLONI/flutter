$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$artifact = Join-Path $env:GITHUB_WORKSPACE 'engine-artifacts'
New-Item -ItemType Directory -Path $artifact | Out-Null
# Keep paths short for upstream build steps that use the Windows MAX_PATH limit.
$root = Join-Path ([IO.Path]::GetPathRoot($env:GITHUB_WORKSPACE)) 'otz'
$source = Join-Path $root 'flutter'
$depotTools = Join-Path $root 'depot_tools'
New-Item -ItemType Directory -Path $root | Out-Null

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -version '[17,18)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio 2022 with C++ tooling is required' }
$env:GYP_MSVS_OVERRIDE_PATH = $vs
$msvc = (Get-Content (Join-Path $vs 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
$winSdk = '10.0.22621.0'
$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
foreach ($arch in ('x64', $env:OTZARIA_ARCH | Select-Object -Unique)) {
    if ($msvc -notlike '14.44.*' -or -not (Test-Path (Join-Path $vs "VC\Tools\MSVC\$msvc\lib\$arch\libcmt.lib"))) {
        throw "MSVC 14.44 $arch libraries are required (found $msvc)"
    }
    if (-not (Test-Path (Join-Path $kits "Lib\$winSdk\um\$arch\kernel32.lib"))) {
        throw "Windows SDK $winSdk $arch libraries are required"
    }
}
@(
    "GYP_MSVS_OVERRIDE_PATH=$vs"
    "OTZARIA_MSVC_VERSION=$msvc"
    "OTZARIA_WINDOWS_SDK=$winSdk"
    "OTZARIA_FLUTTER_SOURCE=$source"
    "OTZARIA_BUILD_ROOT=$root"
) >> $env:GITHUB_ENV

git config --global core.autocrlf false
git config --global core.longpaths true
git init "$source"
git -C "$source" remote add origin https://github.com/palmoni5/flutter.git
git -C "$source" fetch --no-tags --depth=1 origin $env:OTZARIA_A11Y_SOURCE
git -C "$source" checkout --detach FETCH_HEAD
if ((git -C "$source" rev-parse HEAD) -ne $env:OTZARIA_A11Y_SOURCE) {
    throw 'Unexpected Flutter source revision'
}

git init "$depotTools"
git -C "$depotTools" remote add origin https://chromium.googlesource.com/chromium/tools/depot_tools.git
$depotRevision = '35958655b1e171aec866a7615d22a99a737091d1'
git -C "$depotTools" fetch --no-tags --depth=1 origin $depotRevision
git -C "$depotTools" checkout --detach FETCH_HEAD
if ((git -C "$depotTools" rev-parse HEAD) -ne $depotRevision) {
    throw 'Unexpected depot_tools revision'
}
"OTZARIA_DEPOT_TOOLS_REVISION=$depotRevision" >> $env:GITHUB_ENV
"$depotTools" >> $env:GITHUB_PATH
$env:Path = "$depotTools;$env:Path"

Push-Location $source
try {
    # Use Windows-only dependencies and keep the source repository unmanaged.
    $gclient = Get-Content engine/scripts/standard.gclient -Raw
    $gclient = $gclient.Replace('https://github.com/flutter/flutter.git', 'https://github.com/palmoni5/flutter.git')
    $gclient = $gclient.Replace('"custom_deps": {},', @'
"custom_deps": {},
    "custom_vars": {
      "download_jdk": False,
      "download_android_deps": False,
      "setup_githooks": False,
    },
'@)
    Set-Content .gclient $gclient
    & (Join-Path $depotTools 'gclient.bat') sync --no-history --jobs=6 2>&1 |
        Tee-Object -FilePath (Join-Path $artifact 'gclient.log')
    if ((git rev-parse HEAD) -ne $env:OTZARIA_A11Y_SOURCE -or
        (git -C engine/src/flutter/third_party/skia rev-parse HEAD) -ne $env:OTZARIA_SKIA_VERSION -or
        (git -C engine/src/flutter/third_party/dart rev-parse HEAD) -ne $env:OTZARIA_DART_VERSION) {
        throw 'Dependency revision does not match the pinned source'
    }
}
finally {
    Pop-Location
}
(Get-PSDrive -Name ([IO.Path]::GetPathRoot($root).Substring(0, 1))) | Format-List Name, Used, Free

# tools/gn invokes git.bat on Windows. The hosted runner supplies git.exe.
if (-not (Get-Command git.bat -ErrorAction SilentlyContinue)) {
    $gitExe = (Get-Command git.exe -CommandType Application).Source
    $toolShims = Join-Path $root 'tool-shims'
    New-Item -ItemType Directory -Path $toolShims | Out-Null
    @(
        '@echo off'
        ('"{0}" %*' -f $gitExe)
        'exit /b %errorlevel%'
    ) | Set-Content -Encoding ascii (Join-Path $toolShims 'git.bat')
    "$toolShims" >> $env:GITHUB_PATH
    $env:Path = "$toolShims;$env:Path"
}
# Use the same subprocess invocation as GN to verify the batch-file lookup.
python -c "import subprocess; subprocess.check_call(['git.bat', '--version'])"
