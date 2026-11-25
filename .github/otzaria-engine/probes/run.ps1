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
$release = '3.47.7'
$releaseCommit = 'abaf9c523780a608bd46686fd5e53740a07077f8'
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

& $flutter create --empty --platforms=windows --project-name=paragraph_probe $probe
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
        'x64' = 'cc04e8c75d7b8740b3b2705e87a9f9d6839366518ad1eb842e33c6efd2048818'
        'arm64' = 'ed7d43bbc77af371cb44303d9484503417761c2ba36480982bc467552c888eab'
    }[$arch]
    $baselineZip = Join-Path $env:OTZARIA_BUILD_ROOT "a11y-$zipName"
    $baselineUrl = "https://github.com/palmoni5/flutter/releases/download/otzaria-3.47.7-a11y.1/$zipName"
    Invoke-WebRequest $baselineUrl -OutFile $baselineZip
    if ((Get-FileHash $baselineZip).Hash -ne $baselineHash) {
        throw "Unexpected accessibility release SHA256 for $zipName"
    }
    Expand-Archive -LiteralPath $baselineZip -DestinationPath $baselineDir
}
$hashes = [ordered]@{ appSnapshotSha256 = $probeHash }

foreach ($variant in 'stock', 'a11y', 'windows-numpad', 'both', 'skia-style') {
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
    $process = Start-Process $exe -WorkingDirectory $output -ArgumentList ('"{0}"' -f $report) -PassThru
    if (-not $process.WaitForExit(600000)) {
        $process.Kill()
        throw "Paragraph probe timed out with $variant"
    }
    if ($process.ExitCode -ne 0 -or -not (Test-Path $report)) {
        throw "Paragraph probe failed with $variant, exit code $($process.ExitCode)"
    }
}
$hashes | ConvertTo-Json | Set-Content (Join-Path $artifact 'sha256.json')
foreach ($variant in 'windows-numpad', 'both', 'skia-style') {
    python (Join-Path $PSScriptRoot 'compare_paragraph_style_lookup.py') (Join-Path $artifact 'a11y.json') (Join-Path $artifact "$variant.json") 2>&1 |
        Tee-Object -FilePath (Join-Path $artifact "$variant-comparison.log")
}
