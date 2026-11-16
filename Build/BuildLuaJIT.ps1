param(
	[Parameter(Mandatory = $true)]
	[string]$SourceDirectory,

	[Parameter(Mandatory = $true)]
	[string]$BuildDirectory,

	[Parameter(Mandatory = $true)]
	[string]$OutputLibrary,

	[Parameter(Mandatory = $true)]
	[string]$Configuration,

	[Parameter(Mandatory = $true)]
	[string]$Platform
)

$ErrorActionPreference = 'Stop'

$sourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
$buildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
$outputLibrary = [IO.Path]::GetFullPath($OutputLibrary)
$buildSourceDirectory = Join-Path $buildDirectory 'src'

function Copy-DirectoryContents([string]$Source, [string]$Destination)
{
	New-Item -ItemType Directory -Path $Destination -Force | Out-Null
	Get-ChildItem -LiteralPath $Source -Force |
		Copy-Item -Destination $Destination -Recurse -Force
}

# Disable FFI and suppress warnings from LuaJIT on newer MSVC toolsets.
$env:LUAJIT_DISABLE_FFI = '1'
$env:CL = ("$env:CL /wd4244 /wd5287").Trim()
if ($Platform -eq 'ARM64')
{
	# The ARM64 VM source that DynASM generates for buildvm negates unsigned constants throughout.
	$env:CL += ' /wd4146'
}

Copy-DirectoryContents (Join-Path $sourceDirectory 'src') $buildSourceDirectory
Copy-DirectoryContents (Join-Path $sourceDirectory 'dynasm') (Join-Path $buildDirectory 'dynasm')
Copy-Item -LiteralPath (Join-Path $sourceDirectory '.relver') -Destination $buildDirectory -Force

# Keep Git from treating the staging directory as part of the parent worktree.
$gitBin = Join-Path $env:ProgramFiles 'Git\bin'
$env:Path = "$gitBin;$env:Path"
$env:GIT_CEILING_DIRECTORIES = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& git -C $buildDirectory apply --no-index --whitespace=nowarn (Join-Path $PSScriptRoot 'CustomLuaJIT.patch')
if ($LASTEXITCODE -ne 0)
{
	exit $LASTEXITCODE
}

if (-not (Select-String -LiteralPath (Join-Path $buildSourceDirectory 'msvcbuild.bat') -SimpleMatch 'LUAJIT_DISABLE_FFI' -Quiet))
{
	throw 'CustomLuaJIT.patch was not applied to the staged LuaJIT sources.'
}

$builtLibrary = Join-Path $buildSourceDirectory 'lua51.lib'
Remove-Item -LiteralPath $builtLibrary -Force -ErrorAction SilentlyContinue

$buildArguments = if ($Configuration -eq 'Debug') { 'debug static' } else { 'static' }
$msvcBuild = Join-Path $buildSourceDirectory 'msvcbuild.bat'
$buildCommand = "call `"$msvcBuild`" $buildArguments"

# msvcbuild.bat picks its target from the developer command prompt it runs in, not from MSBuild.
# ARM64EC can link LuaJIT's supported x64 output, while native ARM64 needs LuaJIT's own ARM64
# build.
$targetArchitecture = switch ($Platform)
{
	'ARM64EC' { 'x64' }
	'ARM64' { 'arm64' }
}
if ($targetArchitecture)
{
	$vsInstallDirectory = $env:VSINSTALLDIR
	if (-not $vsInstallDirectory)
	{
		# Not started from a developer command prompt (e.g. plain msbuild.exe), so ask vswhere.
		$vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
		if (Test-Path -LiteralPath $vsWhere -PathType Leaf)
		{
			$vsInstallDirectory = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
				Select-Object -First 1
		}
	}
	if (-not $vsInstallDirectory)
	{
		throw "Building LuaJIT for $Platform requires a Visual Studio developer command prompt (VSINSTALLDIR is not set)."
	}

	$vsDevCmd = Join-Path $vsInstallDirectory 'Common7\Tools\VsDevCmd.bat'
	if (-not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf))
	{
		throw "VsDevCmd.bat not found: $vsDevCmd"
	}

	# msvcbuild.bat runs the tools it builds first (minilua, buildvm). On an x64 machine it builds
	# those for x64 and cross-compiles LuaJIT itself. An ARM64 machine with the ARM64-hosted
	# compiler builds everything natively.
	$hostArchitecture = 'x64'
	if ($targetArchitecture -eq 'arm64')
	{
		# Read from the registry, since this script may be running in an emulated x64 process.
		$machine = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE
		$nativeCompiler = Join-Path $vsInstallDirectory 'VC\Tools\MSVC\*\bin\HostARM64\arm64\cl.exe'
		if ($machine -eq 'ARM64' -and (Test-Path -Path $nativeCompiler -PathType Leaf))
		{
			$hostArchitecture = 'arm64'
		}
	}

	# VsDevCmd.bat prepends to PATH every time it runs, and msvcbuild.bat runs it once more for its
	# host tools. On top of a PATH that a developer command prompt and MSBuild have both extended
	# already, that exceeds the 8191 characters cmd.exe accepts ("The input line is too long").
	# So drop what they set up and let VsDevCmd.bat start over from the system directories.
	$systemDirectory = [Environment]::SystemDirectory
	$env:Path = @(
		$systemDirectory,
		$env:SystemRoot,
		(Join-Path $systemDirectory 'Wbem'),
		(Join-Path $systemDirectory 'WindowsPowerShell\v1.0')
	) -join ';'
	Remove-Item -Path Env:__VSCMD_*, Env:VSCMD_*, Env:INCLUDE, Env:LIB, Env:LIBPATH, Env:EXTERNAL_INCLUDE -ErrorAction SilentlyContinue
	$env:VSCMD_SKIP_SENDTELEMETRY = '1'

	$buildCommand = "call `"$vsDevCmd`" -arch=$targetArchitecture -host_arch=$hostArchitecture -no_logo && $buildCommand"
}

Push-Location $buildSourceDirectory
try
{
	& $env:ComSpec /d /s /c $buildCommand
	if ($LASTEXITCODE -ne 0)
	{
		exit $LASTEXITCODE
	}
}
finally
{
	Pop-Location
}

if (-not (Test-Path -LiteralPath $builtLibrary -PathType Leaf))
{
	throw 'LuaJIT did not produce lua51.lib.'
}

$outputDirectory = Split-Path -Parent $outputLibrary
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Copy-Item -LiteralPath $builtLibrary -Destination $outputLibrary -Force
