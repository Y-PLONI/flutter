$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$arch = $env:OTZARIA_ARCH
$hostArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if ($arch -notin @('x64', 'arm64') -or $hostArch -ne $arch) {
    throw "Expected a native Windows $arch runner, found $hostArch"
}
$artifact = Join-Path $env:GITHUB_WORKSPACE 'paragraph-validation'
$buildArtifact = Join-Path $env:GITHUB_WORKSPACE 'engine-artifacts'
$probe = Join-Path $env:OTZARIA_BUILD_ROOT 'paragraph_probe'
$sdk = Join-Path $env:OTZARIA_BUILD_ROOT 'release-sdk'
$release = '3.47.9'
$releaseCommit = 'c197ca5199e9ee5661e865596c9c07294dfab51c'
New-Item -ItemType Directory -Path $artifact | Out-Null

git clone --branch $release --depth=1 https://github.com/flutter/flutter.git $sdk
if ((git -C $sdk rev-parse HEAD) -ne $releaseCommit) { throw "Unexpected Flutter $release revision" }
$flutter = Join-Path $sdk 'bin/flutter.bat'
# Bootstrap can write dependency resolution to stdout before the version JSON.
& $flutter --version 2>&1 | Tee-Object -FilePath (Join-Path $artifact 'flutter-bootstrap.log')
$versionText = (& $flutter --version --machine) -join "`n"
$jsonStart = $versionText.IndexOf('{')
if ($jsonStart -lt 0) { throw "Flutter version JSON was missing: $versionText" }
$version = $versionText.Substring($jsonStart)
$engineRevision = (ConvertFrom-Json $version).engineRevision
if ($engineRevision -ne $env:OTZARIA_ENGINE_VERSION) {
    throw "Unexpected Flutter engine revision $engineRevision"
}
$version | Set-Content (Join-Path $artifact 'flutter-version.json')

# Flutter recognizes the surrounding Flutter checkout as its own repository.
Push-Location $env:OTZARIA_BUILD_ROOT
try {
    & $flutter create --empty --platforms=windows --project-name=paragraph_probe $probe 2>&1 |
        Tee-Object -FilePath (Join-Path $artifact 'app-create.log')
}
finally { Pop-Location }
Copy-Item (Join-Path $PSScriptRoot 'paragraph_style_lookup_probe.dart') (Join-Path $probe 'lib/main.dart') -Force
Push-Location $probe
try {
    & $flutter build windows --release 2>&1 | Tee-Object -FilePath (Join-Path $artifact 'app-build.log')
}
finally { Pop-Location }
$releaseDir = Join-Path $probe "build/windows/$arch/runner/Release"
$probeHash = (Get-FileHash (Join-Path $releaseDir 'data/app.so')).Hash.ToLowerInvariant()
$baselineDir = Join-Path $env:OTZARIA_BUILD_ROOT 'baseline'
$baselineDll = Join-Path $baselineDir 'flutter_windows.dll'
$zipName = "flutter_windows-windows-$arch-release.zip"
if (-not (Test-Path $baselineDll)) {
    $baselineHash = @{
        'x64' = '47600fb0bab510e6adebdaca117fdcaf7cabf67fb91d768a373276315a1305a3'
        'arm64' = '5b12b1e6f66f3b8220ac1e14b95a359edbe43cdb869557b986e2dd65ca8f3569'
    }[$arch]
    $baselineZip = Join-Path $env:OTZARIA_BUILD_ROOT "a11y-$zipName"
    $baselineUrl = "https://github.com/Y-PLONI/flutter/releases/download/otzaria-3.47.9-a11y.1/$zipName"
    Invoke-WebRequest $baselineUrl -OutFile $baselineZip
    if ((Get-FileHash $baselineZip).Hash -ne $baselineHash) {
        throw "Unexpected accessibility release SHA256 for $zipName"
    }
    Expand-Archive -LiteralPath $baselineZip -DestinationPath $baselineDir
}
$hashes = [ordered]@{ appSnapshotSha256 = $probeHash }
$variants = @('skia-style', 'both')

foreach ($variant in (@('stock', 'a11y') + $variants)) {
    $output = Join-Path $env:OTZARIA_BUILD_ROOT "probe-$variant"
    Copy-Item $releaseDir -Destination $output -Recurse
    $dll = Join-Path $output 'flutter_windows.dll'
    if ($variant -eq 'a11y') {
        Copy-Item $baselineDll -Destination $dll -Force
    } elseif ($variant -ne 'stock') {
        $zip = Join-Path $buildArtifact "$variant/$zipName"
        $expanded = Join-Path $env:OTZARIA_BUILD_ROOT "probe-engine-$variant"
        Expand-Archive -LiteralPath $zip -DestinationPath $expanded
        Copy-Item (Join-Path $expanded 'flutter_windows.dll') -Destination $dll -Force
    }
    $hashes[$variant] = (Get-FileHash $dll).Hash.ToLowerInvariant()

    $exe = Join-Path $output 'paragraph_probe.exe'
    $report = Join-Path $artifact "$variant.json"
    $arguments = '"{0}"' -f $report
    if ($variant -in $variants) {
        $arguments += ' --large'
    }
    $process = Start-Process $exe -WorkingDirectory $output -ArgumentList $arguments -PassThru
    if (-not $process.WaitForExit(600000)) {
        $process.Kill()
        throw "Paragraph probe timed out with $variant"
    }
    if ($process.ExitCode -ne 0 -or -not (Test-Path $report)) {
        throw "Paragraph probe failed with $variant, exit code $($process.ExitCode)"
    }
}
$hashes | ConvertTo-Json | Set-Content (Join-Path $artifact 'sha256.json')
python (Join-Path $PSScriptRoot 'compare_paragraph_style_lookup.py') (Join-Path $artifact 'stock.json') (Join-Path $artifact 'a11y.json') 2>&1 |
    Tee-Object -FilePath (Join-Path $artifact 'a11y-comparison.log')
if ($LASTEXITCODE -ne 0) { throw 'Accessibility baseline differs from official engine geometry' }
foreach ($variant in $variants) {
    python (Join-Path $PSScriptRoot 'compare_paragraph_style_lookup.py') (Join-Path $artifact 'a11y.json') (Join-Path $artifact "$variant.json") 2>&1 |
        Tee-Object -FilePath (Join-Path $artifact "$variant-comparison.log")
    if ($LASTEXITCODE -ne 0) { throw "Paragraph geometry of $variant differs from accessibility baseline" }
}

# Confirm that both large paragraph scenarios ran on each patched engine.
foreach ($variant in $variants) {
    $report = Get-Content (Join-Path $artifact "$variant.json") -Raw | ConvertFrom-Json
    if ($report.large.characters -ne 1985804 -or $report.large.lineCount -lt 1 -or $report.large.layoutMicros -lt 1) {
        throw "Missing or incomplete large mixed-style paragraph evidence for $variant"
    }
    $singleRun = $report.largeSingleRun
    if ($singleRun.characters -ne 1985800 -or $singleRun.lineCount -lt 1 -or
        $singleRun.layoutMicros -lt 1 -or $singleRun.widthRelayoutLineCount -lt 1 -or
        $singleRun.widthRelayoutMicros -lt 1) {
        throw "Missing or incomplete large justified paragraph evidence for $variant"
    }
    Write-Output "$variant large mixed paragraph ($($report.large.characters) characters): $($report.large.layoutMicros) us"
    Write-Output "$variant large justified paragraph ($($singleRun.characters) characters): $($singleRun.layoutMicros) us; width re-layout $($singleRun.widthRelayoutMicros) us"
}
