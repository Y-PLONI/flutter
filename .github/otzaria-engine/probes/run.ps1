$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

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
$version = & $flutter --version --machine
$engineRevision = (ConvertFrom-Json ($version -join "`n")).engineRevision
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
$releaseDir = Join-Path $probe 'build/windows/x64/runner/Release'
$probeHash = (Get-FileHash (Join-Path $releaseDir 'data/app.so')).Hash.ToLowerInvariant()
$baselineDll = Join-Path $env:OTZARIA_BUILD_ROOT 'baseline/flutter_windows.dll'
$zipName = 'flutter_windows-windows-x64-release.zip'
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
