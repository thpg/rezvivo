# Desktop recording dependency. Only the encoder and its notices enter the setup.
param([string]$Archive = '')
$ErrorActionPreference = 'Stop'
$url = 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip'
$sha = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
$runtime = Join-Path $PSScriptRoot 'video'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
if (!$Archive) {
    $Archive = Join-Path $env:TEMP 'rezvivo-ffmpeg-9.0.2.zip'
    if (!(Test-Path -LiteralPath $Archive)) {
        Invoke-WebRequest -Uri $url -OutFile $Archive -UseBasicParsing
    }
}
if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {
    throw 'Video encoder archive SHA256 mismatch.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Archive).Path)
try {
    foreach ($name in @('ffmpeg.exe', 'LICENSE')) {
        $entry = @($zip.Entries | Where-Object { $_.Name -eq $name })
        if ($entry.Count -ne 1) { throw "Archive has no unique $name" }
        $target = Join-Path $runtime $(if ($name -eq 'LICENSE') { 'LICENSE.txt' } else { $name })
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry[0], $target, $true)
    }
} finally { $zip.Dispose() }
$notice = @'
FFmpeg 9.0.2, essentials Windows build by Gyan Doshi. GPL v3.
https://ffmpeg.org/
Binary build, dependencies and source references:
https://www.gyan.dev/ffmpeg/builds/
https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip
Source code: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
Source revision: https://github.com/FFmpeg/FFmpeg/commit/946fcce07b
The exact configure options are printed by ffmpeg.exe -buildconf.
libx264 source: https://code.videolan.org/videolan/x264
License text: LICENSE.txt in this directory.
'@
[IO.File]::WriteAllText((Join-Path $runtime 'NOTICE.txt'), $notice, [Text.UTF8Encoding]::new($false))
& (Join-Path $runtime 'ffmpeg.exe') -version | Select-Object -First 1
if ($LASTEXITCODE -ne 0) { throw 'Video encoder validation failed.' }
