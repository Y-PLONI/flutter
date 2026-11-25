$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$source = $env:OTZARIA_FLUTTER_SOURCE
$arch = $env:OTZARIA_ARCH
$artifactDir = Join-Path $env:GITHUB_WORKSPACE 'engine-artifacts'
$engineSrc = Join-Path $source 'engine/src'
$skia = Join-Path $engineSrc 'flutter/third_party/skia'
$ninja = Join-Path $source 'third_party/ninja/ninja.exe'
$clangTools = Join-Path $engineSrc 'flutter/buildtools/windows-x64/clang/bin'
$readobj = Join-Path $clangTools 'llvm-readobj.exe'
$buildDir = if ($arch -eq 'x64') { 'out/host_release' } else { 'out/host_release_arm64' }
$outDir = Join-Path $engineSrc $buildDir
$engineArg = "--gn-args=engine_version=""$env:OTZARIA_ENGINE_VERSION"""
$patches = @{
    'windows-numpad' = Join-Path $PSScriptRoot 'patches/windows-numpad.patch'
    'skia-style' = Join-Path $PSScriptRoot 'patches/skia-style.patch'
}
$zipName = "flutter_windows-windows-$arch-release.zip"
$baselineHash = @{
    'x64' = 'cc04e8c75d7b8740b3b2705e87a9f9d6839366518ad1eb842e33c6efd2048818'
    'arm64' = 'ed7d43bbc77af371cb44303d9484503417761c2ba36480982bc467552c888eab'
}[$arch]
$baselineUrl = "https://github.com/palmoni5/flutter/releases/download/otzaria-3.47.7-a11y.1/$zipName"
$baselinePath = Join-Path $env:OTZARIA_BUILD_ROOT $zipName
$baselineDir = Join-Path $env:OTZARIA_BUILD_ROOT 'baseline'
Invoke-WebRequest $baselineUrl -OutFile $baselinePath
if ((Get-FileHash $baselinePath).Hash -ne $baselineHash) {
    throw "Unexpected accessibility release SHA256 for $zipName"
}
Expand-Archive -LiteralPath $baselinePath -DestinationPath $baselineDir

function Read-Exports($dll) {
    $lines = & $readobj --file-headers --coff-exports $dll
    $machine = if ($arch -eq 'x64') { 'IMAGE_FILE_MACHINE_AMD64' } else { 'IMAGE_FILE_MACHINE_ARM64' }
    if (-not ($lines -match "Machine: $machine ")) {
        throw "Expected $machine in $dll"
    }
    $exports = @($lines | Where-Object { $_ -match '^  (Ordinal|Name): ' })
    if ($exports.Count -eq 0) { throw "No PE exports in $dll" }
    return $exports
}

$baselineExports = Read-Exports (Join-Path $baselineDir 'flutter_windows.dll')
$baselineExports | Set-Content (Join-Path $artifactDir 'baseline-exports.txt')
$clangVersion = & (Join-Path $clangTools 'clang-cl.exe') --version
$clangVersion | Set-Content (Join-Path $artifactDir 'clang-version.txt')

# Validate both patches before spending time compiling. They target independent repositories.
git -C $source apply --check $patches['windows-numpad']
git -C $skia apply --check $patches['skia-style']
git -C $source apply $patches['windows-numpad']
Push-Location $engineSrc
try {
    python flutter/tools/gn --runtime-mode release --no-lto --no-goma --no-rbe "--windows-cpu=$arch" $engineArg 2>&1 |
        Tee-Object -FilePath (Join-Path $artifactDir 'configure.log')
    $argsGn = Join-Path $outDir 'args.gn'
    if ((Get-Content $argsGn -Raw) -notmatch ('(?m)^engine_version\s*=\s*"' + $env:OTZARIA_ENGINE_VERSION + '"\s*$')) {
        throw "Expected release engine revision in $argsGn"
    }
    Copy-Item $argsGn $artifactDir

    foreach ($variant in 'windows-numpad', 'both', 'skia-style') {
        switch ($variant) {
            'windows-numpad' { $applied = @('windows-numpad') }
            'both' {
                git -C $skia apply $patches['skia-style']
                $applied = @('windows-numpad', 'skia-style')
            }
            'skia-style' {
                git -C $source apply --reverse $patches['windows-numpad']
                $applied = @('skia-style')
            }
        }
        & $ninja -C $buildDir -j 3 flutter_windows 2>&1 |
            Tee-Object -FilePath (Join-Path $artifactDir "$variant-build.log")

        $dll = Join-Path $outDir 'flutter_windows.dll'
        $exports = Read-Exports $dll
        $exports | Set-Content (Join-Path $artifactDir "$variant-exports.txt")
        if ((Compare-Object $baselineExports $exports -SyncWindow 0 -CaseSensitive)) {
            throw "Windows PE export names or ordinals changed for $variant"
        }
        $dest = Join-Path $artifactDir $variant
        New-Item -ItemType Directory -Path $dest | Out-Null
        $binaries = @('flutter_windows.dll', 'flutter_windows.dll.exp', 'flutter_windows.dll.lib', 'flutter_windows.dll.pdb')
        $files = foreach ($binary in $binaries) {
            $path = Join-Path $outDir $binary
            if ((Get-Item $path).Length -eq 0) { throw "Empty build output $path" }
            $path
        }

        $archive = Join-Path $dest $zipName
        Compress-Archive -LiteralPath $files -DestinationPath $archive -CompressionLevel Optimal
        $checksums = foreach ($file in @($archive) + $files) {
            "{0}  {1}" -f (Get-FileHash $file).Hash.ToLowerInvariant(), (Split-Path $file -Leaf)
        }
        $checksums | Set-Content (Join-Path $dest 'SHA256SUMS.txt')
        $patchHashes = [ordered]@{}
        foreach ($name in $applied) {
            $patchHashes[$name] = (Get-FileHash $patches[$name]).Hash.ToLowerInvariant()
        }
        [ordered]@{
            variant = $variant
            architecture = $arch
            runtimeMode = 'release'
            sourceRepository = 'https://github.com/palmoni5/flutter'
            sourceCommit = $env:OTZARIA_A11Y_SOURCE
            compatibilityEngineVersion = $env:OTZARIA_ENGINE_VERSION
            skiaCommit = $env:OTZARIA_SKIA_VERSION
            dartCommit = $env:OTZARIA_DART_VERSION
            patchSha256 = $patchHashes
            baselineArchiveSha256 = $baselineHash
            baselineUrl = $baselineUrl
            workflowCommit = $env:GITHUB_SHA
            workflowRun = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
            depotToolsCommit = $env:OTZARIA_DEPOT_TOOLS_REVISION
            runnerImage = $env:ImageVersion
            visualCppVersion = $env:OTZARIA_MSVC_VERSION
            windowsSdkVersion = $env:OTZARIA_WINDOWS_SDK
            clangVersion = $clangVersion
        } | ConvertTo-Json | Set-Content (Join-Path $dest 'provenance.json')
    }

    if ($arch -eq 'x64') {
        # Restore the keyboard patch before building the Windows test fixture.
        git -C $source apply $patches['windows-numpad']
        & $ninja -C $buildDir -j 3 flutter_windows_unittests 2>&1 |
            Tee-Object -FilePath (Join-Path $artifactDir 'keyboard-unittests-build.log')
        Push-Location $outDir
        try {
            ./flutter_windows_unittests.exe '--gtest_filter=KeyboardKeyEmbedderHandlerTest.*' 2>&1 |
                Tee-Object -FilePath (Join-Path $artifactDir 'keyboard-unittests.log')
        }
        finally { Pop-Location }
    }
}
finally { Pop-Location }
