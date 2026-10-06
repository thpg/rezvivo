param([string]$Glslang = '')
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$headers = Join-Path $PSScriptRoot '.deps\Vulkan-Headers'
if (-not (Test-Path -LiteralPath "$headers\include\vulkan\vulkan.h")) {
    git clone --depth 1 --branch vulkan-sdk-1.3.296.0 https://github.com/KhronosGroup/Vulkan-Headers.git $headers
    if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch pinned Khronos headers' }
}
$commit = (git -C $headers rev-parse HEAD).Trim()
if ($commit -ne '29f979ee5aa58b7b005f805ea8df7a855c39ff37') { throw 'Unexpected Vulkan-Headers revision' }
if (-not $Glslang) {
    $compiler = Get-Command glslangValidator,glslang -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($compiler) { $Glslang = $compiler.Source }
    elseif ($env:VULKAN_SDK) { $Glslang = Join-Path $env:VULKAN_SDK 'Bin\glslangValidator.exe' }
}
if (-not $Glslang -or -not (Test-Path -LiteralPath $Glslang)) { throw 'Pass -Glslang <glslang executable>, or install it on PATH / in VULKAN_SDK' }
New-Item -ItemType Directory -Force -Path 'build' | Out-Null
$ErrorActionPreference = 'Continue' # PS 5.1 treats native informational stderr as errors when redirected.
$shaderCommand = '"' + $Glslang + '" -V --target-env vulkan1.2 -o build\shadow.spv shadow.comp 2>&1'
& $env:ComSpec /d /s /c $shaderCommand
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { throw 'Ray query shader failed' }
$ErrorActionPreference = 'Continue'
$reflectionCommand = '"' + $Glslang + '" -V --target-env vulkan1.2 -o build\reflection.spv reflection.comp 2>&1'
& $env:ComSpec /d /s /c $reflectionCommand
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { throw 'Reflection ray query shader failed' }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $vs) { throw 'Visual C++ x64 build tools are required for the optional RTX bridge' }
$vc = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
# Only compiler invocation crosses to cmd; there are no filesystem deletions/moves.
$line = 'call "' + $vc + '" >nul && cl /nologo /std:c++17 /O2 /EHsc /MT /LD /W4 /DWIN32_LEAN_AND_MEAN /DNOMINMAX /I"' + $headers + '\include" rtx_bridge.cpp /Fobuild\ /Febuild\rezvivo_rtx.dll /link opengl32.lib /IMPLIB:build\rezvivo_rtx.lib'
$ErrorActionPreference = 'Continue'
& $env:ComSpec /d /s /c $line
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { throw 'RTX bridge compilation failed' }
Copy-Item -LiteralPath 'build\rezvivo_rtx.dll' -Destination '..\rezvivo_rtx.dll' -Force
New-Item -ItemType Directory -Force -Path '..\data\shaders\rtx' | Out-Null
Copy-Item -LiteralPath 'build\shadow.spv' -Destination '..\data\shaders\rtx\shadow.spv' -Force
Copy-Item -LiteralPath 'build\reflection.spv' -Destination '..\data\shaders\rtx\reflection.spv' -Force
