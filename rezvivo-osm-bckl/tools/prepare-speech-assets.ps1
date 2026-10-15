param([string]$CacheDirectory = (Join-Path $env:LOCALAPPDATA 'REZVIVO\Downloads\speech'))
# Optional offline speech resources. No compiler or Python runtime is needed.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$speechRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\data\speech'))
$archiveRoot = [IO.Path]::GetFullPath($CacheDirectory)
[IO.Directory]::CreateDirectory($speechRoot) | Out-Null
[IO.Directory]::CreateDirectory($archiveRoot) | Out-Null
$packages = @(
    @{ name='vosk-win64-0.3.45'; destination='vosk-win64'; url='https://github.com/alphacep/vosk-api/releases/download/v0.3.45/vosk-win64-0.3.45.zip'; sha256='f1dcc9cca460630f81ea8f71794f69c80bed6556d2a4e6237b5785e1d2dff34b'; native=$true },
    @{ name='vosk-model-small-ru-0.22'; destination='models/ru'; url='https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip'; sha256='961d5ff98a17f4aa6de69864d0aa71fa5bac682301d2b5d17a3f24c5c99a46d4'; native=$false },
    @{ name='vosk-model-small-en-us-0.15'; destination='models/en'; url='https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip'; sha256='30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498'; native=$false }
)
$runtimeDlls = @('libvosk.dll','libstdc++-6.dll','libwinpthread-1.dll','libgcc_s_seh-1.dll')
$runtimeFiles = @()
foreach ($package in $packages) {
    $archivePath = Join-Path $archiveRoot ($package.name + '.zip')
    if (!(Test-Path -LiteralPath $archivePath)) {
        Write-Output ('Downloading ' + $package.name)
        Invoke-WebRequest -UseBasicParsing -Uri $package.url -OutFile $archivePath
    }
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $package.sha256) {
        throw ('Speech archive checksum mismatch: ' + $archivePath)
    }
    $targetRoot = [IO.Path]::GetFullPath((Join-Path $speechRoot $package.destination))
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $prefix = $package.name + '/'
            if (!$entry.FullName.StartsWith($prefix,[StringComparison]::Ordinal)) { throw 'Unexpected speech archive root' }
            $relativeName = $entry.FullName.Substring($prefix.Length)
            if ($package.native -and ($runtimeDlls -notcontains $relativeName)) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $targetRoot $relativeName))
            if (!$target.StartsWith($targetRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid speech archive path' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$true)
            $runtimeFiles += [ordered]@{ path=$target.Substring($speechRoot.Length+1).Replace('\','/'); bytes=(Get-Item -LiteralPath $target).Length; sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
    } finally { $archive.Dispose() }
    Write-Output ('Prepared ' + $package.name)
}
$manifest = [ordered]@{
    schema_version=1
    engine='Vosk'; engine_version='0.3.45'
    source='https://github.com/alphacep/vosk-api/tree/v0.3.45'
    models_source='https://alphacephei.com/vosk/models'
    packages=@($packages | ForEach-Object { [ordered]@{ name=$_.name; destination=$_.destination; url=$_.url; sha256=$_.sha256 } })
    files=$runtimeFiles
}
[IO.File]::WriteAllText((Join-Path $speechRoot 'assets.json'),($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$totalBytes = 0L
foreach ($runtimeFile in $runtimeFiles) { $totalBytes += $runtimeFile.bytes }
Write-Output ('Speech runtime: ' + $runtimeFiles.Count + ' files; ' + [Math]::Round($totalBytes/1MB,1) + ' MiB')
