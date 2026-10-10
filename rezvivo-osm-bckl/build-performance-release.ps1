# Build all application and CGE units with the same Release options.
# Uses only authoritative source directories, with separate PPUs and symbols.
param(
    [Parameter(Mandatory=$true)][string]$EngineRoot,
    [Parameter(Mandatory=$true)][string]$Compiler,
    [string]$OutputName = 'third_person_navigation.exe',
    [switch]$BuildRtx,
    [string]$Glslang = ''
)
$ErrorActionPreference = 'Stop'
$EngineRoot = (Resolve-Path -LiteralPath $EngineRoot).Path
$Compiler = (Resolve-Path -LiteralPath $Compiler).Path
if ([IO.Path]::GetFileName($OutputName) -ne $OutputName) { throw 'OutputName must be a filename.' }
$projectRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $projectRoot
& (Join-Path $projectRoot 'tools\generate-release.ps1') -ResourceCompiler (Join-Path (Split-Path -Parent $Compiler) 'windres.exe')
# Runtime shaders are versioned in data/procedural-trees/shaders.
$buildRoot = Join-Path $projectRoot 'castle-engine-output\performance-release'
$unitRoot = Join-Path $buildRoot 'units'
New-Item -ItemType Directory -Path $unitRoot -Force | Out-Null
$options = @('-MObjFPC', '-Scghi', '-Ci', '-O2', '-gw3', '-gl', '-Xg', '-l', '-vewnibq', '-vh-', '-dRELEASE')
$projectDirs = @($projectRoot, (Join-Path $projectRoot 'code'))
foreach ($dir in @('Bikeparametric', 'Osm3d', 'Mcp', 'tree-editor\core', 'tree-editor\render')) {
    $projectDirs += Join-Path $repoRoot $dir
}
foreach ($dir in $projectDirs) { $options += '-Fu' + $dir; $options += '-Fi' + $dir }
$engineUnits = @(
    'src\audio',
    'src\audio\fmod',
    'src\audio\ogg_vorbis',
    'src\audio\openal',
    'src\base',
    'src\base\android',
    'src\base_rendering',
    'src\base_rendering\dglopengl',
    'src\base_rendering\web',
    'src\castlescript',
    'src\delphi',
    'src\deprecated_library',
    'src\deprecated_units',
    'src\files',
    'src\files\indy',
    'src\files\tools',
    'src\fonts',
    'src\images',
    'src\lcl',
    'src\physics\kraft',
    'src\scene',
    'src\scene\load',
    'src\scene\load\collada',
    'src\scene\load\ifc',
    'src\scene\load\md3',
    'src\scene\load\pasgltf',
    'src\scene\load\spine',
    'src\scene\x3d',
    'src\services',
    'src\services\steam',
    'src\transform',
    'src\ui',
    'src\ui\windows',
    'src\vampyre_imaginglib\src\Extensions',
    'src\vampyre_imaginglib\src\Extensions\LibTiff',
    'src\vampyre_imaginglib\src\Extras\Contrib',
    'src\vampyre_imaginglib\src\Extras\Contrib\HqResampler',
    'src\vampyre_imaginglib\src\Extras\Demos\ClippingTest',
    'src\vampyre_imaginglib\src\Extras\DynamicLib',
    'src\vampyre_imaginglib\src\Extras\DynamicLib\ImportHeaders\Delphi.NET',
    'src\vampyre_imaginglib\src\Extras\DynamicLib\ImportHeaders\Pascal',
    'src\vampyre_imaginglib\src\Extras\Extensions',
    'src\vampyre_imaginglib\src\Extras\Packages',
    'src\vampyre_imaginglib\src\Extras\Tools\ImageDebugger',
    'src\vampyre_imaginglib\src\Source',
    'src\vampyre_imaginglib\src\Source\JpegLib',
    'src\vampyre_imaginglib\src\Source\ZLib',
    'src\window',
    'src\window\deprecated_units',
    'src\window\gtk',
    'src\window\gtk\gtk3\gtk3bindings',
    'src\window\unix'
)
$engineIncludes = @(
    'src\scene',
    'src\common_includes',
    'src\base',
    'src\audio',
    'src\audio\fmod',
    'src\audio\openal',
    'src\base\auto_generated_persistent_vectors',
    'src\base\unix',
    'src\base\wasi',
    'src\base\windows',
    'src\base_rendering',
    'src\base_rendering\auto_generated_persistent_vectors',
    'src\base_rendering\glsl\generated-pascal',
    'src\base_rendering\web',
    'src\delphi',
    'src\deprecated_units',
    'src\deprecated_units\auto_generated_persistent_vectors',
    'src\files',
    'src\fonts',
    'src\images',
    'src\lcl',
    'src\physics\kraft',
    'src\scene\auto_generated_persistent_vectors',
    'src\scene\glsl\generated-pascal',
    'src\scene\load',
    'src\scene\load\collada',
    'src\scene\load\ifc',
    'src\scene\load\md3',
    'src\scene\load\spine',
    'src\scene\transform_manipulate_data\generated-pascal',
    'src\scene\x3d',
    'src\scene\x3d\auto_generated_node_helpers',
    'src\scene\x3d\auto_generated_teapot',
    'src\services',
    'src\transform',
    'src\transform\auto_generated_persistent_vectors',
    'src\ui',
    'src\ui\auto_generated_persistent_vectors',
    'src\ui\designs',
    'src\vampyre_imaginglib\src\Source',
    'src\vampyre_imaginglib\src\Source\JpegLib',
    'src\vampyre_imaginglib\src\Source\ZLib',
    'src\window',
    'src\window\gtk',
    'src\window\gtk\gtk3',
    'src\window\unix',
    'src\window\windows'
)
foreach ($dir in $engineUnits) { $options += '-Fu' + (Join-Path $EngineRoot $dir) }
foreach ($dir in $engineIncludes) { $options += '-Fi' + (Join-Path $EngineRoot $dir) }
$options += '-FU' + $unitRoot
$options += '-FE' + $buildRoot
$options += '-o' + (Join-Path $buildRoot $OutputName)
$responsePath = Join-Path $buildRoot 'release.rsp'
# FPC response files require option names outside quotes.
$quotedOptions = $options | ForEach-Object {
    if ($_ -match '^(-F[uUiIE]|-o)(.*\s.*)$') { $Matches[1] + '"' + $Matches[2] + '"' }
    else { $_ }
}
[IO.File]::WriteAllLines($responsePath, $quotedOptions, [Text.UTF8Encoding]::new($false))
Push-Location $projectRoot
try {
    & $Compiler -B ('@' + $responsePath) 'third_person_navigation_standalone.dpr'
    if ($LASTEXITCODE -ne 0) { throw "Release compilation failed: $LASTEXITCODE" }
} finally { Pop-Location }
$builtExecutable = Join-Path $buildRoot $OutputName
$activeExecutable = Join-Path $projectRoot $OutputName
Copy-Item -LiteralPath $builtExecutable -Destination $activeExecutable -Force
# Runtime libraries are supplied separately; see dependencies/runtime.json.
# Optional native ray-query backend. The regular Pascal build does not need a
# C++ compiler or Vulkan SDK; missing/unsupported RTX falls back to raster.
$rtxRoot = Join-Path $repoRoot 'Osm3d'
if ($BuildRtx) {
    Push-Location $rtxRoot
    try { & (Join-Path $rtxRoot 'rtx\build.ps1') -Glslang $Glslang }
    finally { Pop-Location }
}
if (Test-Path -LiteralPath (Join-Path $rtxRoot 'rezvivo_rtx.dll')) {
    Copy-Item -LiteralPath (Join-Path $rtxRoot 'rezvivo_rtx.dll') -Destination $projectRoot -Force
    Copy-Item -LiteralPath (Join-Path $rtxRoot 'rezvivo_rtx.dll') -Destination $buildRoot -Force
    $shaderRoot = Join-Path $projectRoot 'data\shaders\rtx'
    New-Item -ItemType Directory -Path $shaderRoot -Force | Out-Null
    foreach ($shader in @('shadow.spv', 'reflection.spv')) {
        Copy-Item -LiteralPath (Join-Path $rtxRoot ('data\shaders\rtx\' + $shader)) -Destination $shaderRoot -Force
    }
}
Write-Output $activeExecutable
