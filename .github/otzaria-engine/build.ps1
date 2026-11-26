$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$source = $env:OTZARIA_FLUTTER_SOURCE
$arch = $env:OTZARIA_ARCH
$artifactDir = Join-Path $env:GITHUB_WORKSPACE 'engine-artifacts'
$engineSrc = Join-Path $source 'engine/src'
$ninja = Join-Path $source 'third_party/ninja/ninja.exe'
$clangTools = Join-Path $engineSrc 'flutter/buildtools/windows-x64/clang/bin'
$readobj = Join-Path $clangTools 'llvm-readobj.exe'
$buildDir = if ($arch -eq 'x64') { 'out/host_release' } else { 'out/host_release_arm64' }
$outDir = Join-Path $engineSrc $buildDir
$engineArg = "--gn-args=engine_version=""$env:OTZARIA_ENGINE_VERSION"""
$patches = @{
    'windows-numpad' = Join-Path $PSScriptRoot 'patches/windows-numpad.patch'
}
$zipName = "flutter_windows-windows-$arch-release.zip"
# The official engine of the same revision is the export baseline: the fixes must not change the ABI.
$baselineUrl = "https://storage.googleapis.com/flutter_infra_release/flutter/$env:OTZARIA_ENGINE_VERSION/windows-$arch-release/windows-$arch-flutter.zip"
$baselinePath = Join-Path $env:OTZARIA_BUILD_ROOT "official-windows-$arch-flutter.zip"
$baselineDir = Join-Path $env:OTZARIA_BUILD_ROOT 'baseline'
Invoke-WebRequest $baselineUrl -OutFile $baselinePath
$baselineHash = (Get-FileHash $baselinePath).Hash.ToLowerInvariant()
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

# Validate the patch before spending time compiling.
git -C $source apply --check $patches['windows-numpad']
Push-Location $engineSrc
try {
    python flutter/tools/gn --runtime-mode release --no-lto --no-goma --no-rbe "--windows-cpu=$arch" $engineArg 2>&1 |
        Tee-Object -FilePath (Join-Path $artifactDir 'configure.log')
    $argsGn = Join-Path $outDir 'args.gn'
    if ((Get-Content $argsGn -Raw) -notmatch ('(?m)^engine_version\s*=\s*"' + $env:OTZARIA_ENGINE_VERSION + '"\s*$')) {
        throw "Expected release engine revision in $argsGn"
    }
    Copy-Item $argsGn $artifactDir

    foreach ($variant in 'a11y', 'windows-numpad') {
        switch ($variant) {
            'a11y' { $applied = @() }
            'windows-numpad' {
                git -C $source apply $patches['windows-numpad']
                $applied = @('windows-numpad')
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
        $debugDirectory = & $readobj --coff-debug-directory $dll
        $debugDirectory | Set-Content (Join-Path $dest 'debug-directory.txt')
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
            officialArchiveSha256 = $baselineHash
            officialArchiveUrl = $baselineUrl
            workflowCommit = $env:GITHUB_SHA
            workflowRun = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
            depotToolsCommit = $env:OTZARIA_DEPOT_TOOLS_REVISION
            runnerImage = $env:ImageVersion
            visualCppVersion = $env:OTZARIA_MSVC_VERSION
            windowsSdkVersion = $env:OTZARIA_WINDOWS_SDK
            clangVersion = $clangVersion
        } | ConvertTo-Json | Tee-Object -FilePath (Join-Path $dest 'provenance.json')
        $checksums | Write-Output
        @(
            ""
            "### $arch / $variant"
            ""
            '    ' + $checksums[0]
            ""
            '    ' + (($debugDirectory | Select-String 'PDBGUID') -join ' ').Trim()
            ""
        ) >> $env:GITHUB_STEP_SUMMARY
    }

    if ($arch -eq 'x64') {
        $keyboardSource = 'engine/src/flutter/shell/platform/windows/keyboard_key_embedder_handler.cc'
        # Leave the new tests in place while restoring the original handler.
        git -C $source restore --source HEAD -- $keyboardSource
        & $ninja -C $buildDir -j 3 flutter_windows_unittests 2>&1 |
            Tee-Object -FilePath (Join-Path $artifactDir 'keyboard-unittests-build-baseline.log')

        $test = Join-Path $outDir 'flutter_windows_unittests.exe'
        $baselineXml = Join-Path $artifactDir 'keyboard-unittests-baseline.xml'
        Push-Location $outDir
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            & $test '--gtest_filter=KeyboardKeyEmbedderHandlerTest.Numpad*' "--gtest_output=xml:$baselineXml" 2>&1 |
                Tee-Object -FilePath (Join-Path $artifactDir 'keyboard-unittests-baseline.log')
            $baselineExit = $LASTEXITCODE
        }
        finally {
            $PSNativeCommandUseErrorActionPreference = $true
            Pop-Location
        }
        $baselineTests = ([xml](Get-Content $baselineXml -Raw)).testsuites.testsuite.testcase
        $expectedFailures = @(
            'NumpadNavigationUsesNativeVirtualKeys'
            'NumpadNavigationKeepsIdentityAcrossNumLock'
            'NumpadAndDedicatedArrowsStayDistinct'
            'NumpadRecoversAfterMissedRelease'
        )
        $actualFailures = @($baselineTests | Where-Object { $_.failure } | ForEach-Object { $_.name })
        if ($baselineExit -ne 1 -or $baselineTests.Count -ne 6 -or $actualFailures.Count -ne $expectedFailures.Count -or
            (Compare-Object $expectedFailures $actualFailures)) {
            throw "Unexpected baseline exit code/tests/failures: $baselineExit/$($baselineTests.Count)/$actualFailures"
        }

        git -C $source apply "--include=$keyboardSource" $patches['windows-numpad']
        & $ninja -C $buildDir -j 3 flutter_windows_unittests 2>&1 |
            Tee-Object -FilePath (Join-Path $artifactDir 'keyboard-unittests-build.log')
        $fixedXml = Join-Path $artifactDir 'keyboard-unittests.xml'
        Push-Location $outDir
        try {
            & $test '--gtest_filter=KeyboardKeyEmbedderHandlerTest.*' "--gtest_output=xml:$fixedXml" 2>&1 |
                Tee-Object -FilePath (Join-Path $artifactDir 'keyboard-unittests.log')
        }
        finally { Pop-Location }
        $fixedTests = ([xml](Get-Content $fixedXml -Raw)).testsuites.testsuite.testcase
        if (@($fixedTests | Where-Object { $_.name -like 'Numpad*' }).Count -ne 6) {
            throw 'Expected six new numpad cases to pass in the full keyboard suite'
        }
        "Windows keyboard suite passed $($fixedTests.Count) tests. The six new cases include four that failed with the original handler." >> $env:GITHUB_STEP_SUMMARY
    }
}
finally { Pop-Location }
