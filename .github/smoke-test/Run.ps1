<#
.SYNOPSIS
Runs a portable Rainmeter build for a few seconds and checks that it works as a native ARM64 process.

.DESCRIPTION
Used by the smoke-test job of the build-arm64 workflow. It can also be run by hand on any Windows
on ARM device:

    .\.github\smoke-test\Run.ps1 -Package Rainmeter-ARM64-Portable.zip -WorkDirectory $env:TEMP\RainmeterSmokeTest

The build is started with its default layout plus the SmokeTest skin next to this script. The skin
reports its results in Rainmeter's log, which is what gets checked.

.PARAMETER Package
Rainmeter-ARM64-Portable.zip, or the folder it was extracted to.

.PARAMETER WorkDirectory
The folder to run the build in. It is deleted first. The log and a screenshot end up in its
Results subfolder.

.PARAMETER TimeoutSeconds
How long to wait for the expected log lines.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$Package,

	[Parameter(Mandatory)]
	[string]$WorkDirectory,

	[int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

$root = Join-Path $WorkDirectory 'Rainmeter'
$results = Join-Path $WorkDirectory 'Results'
$failures = [Collections.Generic.List[string]]::new()

function Read-SharedFile {
	param([string]$Path)

	# Rainmeter appends to its log while this script reads it.
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
	$stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
	try {
		return [IO.StreamReader]::new($stream).ReadToEnd()
	} finally {
		$stream.Dispose()
	}
}

function Save-Screenshot {
	param([string]$Path)

	# Only there to look at afterwards, so never a reason to fail.
	try {
		Add-Type -AssemblyName System.Drawing, System.Windows.Forms
		$bounds = [Windows.Forms.SystemInformation]::VirtualScreen
		$bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
		try {
			$graphics = [Drawing.Graphics]::FromImage($bitmap)
			try {
				$graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
			} finally {
				$graphics.Dispose()
			}
			$bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
		} finally {
			$bitmap.Dispose()
		}
	} catch {
		Write-Host "No screenshot: $($_.Exception.Message)"
	}
}

# GetProcessInformation() reports the architecture a process really runs as. Unlike
# IsWow64Process2(), it also tells an emulated x64 process apart from a native ARM64 one.
Add-Type -Namespace RainmeterSmokeTest -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct ProcessMachineInformation
{
	public ushort ProcessMachine;
	public ushort Reserved;
	public uint MachineAttributes;
}

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GetProcessInformation(IntPtr process, int informationClass, out ProcessMachineInformation information, int size);
'@
$processMachineTypeInfo = 9
$imageFileMachineArm64 = 0xAA64

# --- Set up the build with logging on and the test skin loaded ------------------------------------

Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $root, $results | Out-Null

if (Test-Path -LiteralPath $Package -PathType Leaf) {
	Expand-Archive -LiteralPath $Package -DestinationPath $root
} else {
	Copy-Item -Path (Join-Path $Package '*') -Destination $root -Recurse
}

$exe = Join-Path $root 'Rainmeter.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
	throw "Rainmeter.exe not found in $Package"
}

# The test skin goes in with the default skins, which Rainmeter copies to its Skins folder when it
# first starts. That way the test also covers the first start of a freshly extracted package.
$skin = Join-Path $root 'Defaults\Skins\SmokeTest'
New-Item -ItemType Directory -Path $skin | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SmokeTest.ini'), (Join-Path $PSScriptRoot 'SmokeTest.lua') -Destination $skin

# An x86 DLL stands in for a plugin that was not built for ARM64.
$foreignDll = Join-Path $env:SystemRoot 'SysWOW64\version.dll'
$hasForeignPlugin = Test-Path -LiteralPath $foreignDll -PathType Leaf
if ($hasForeignPlugin) {
	New-Item -ItemType Directory -Path (Join-Path $root 'Plugins') -Force | Out-Null
	Copy-Item -LiteralPath $foreignDll -Destination (Join-Path $root 'Plugins\NotArm64.dll')
}

$settingsPath = Join-Path $root 'Rainmeter.ini'
$settings = [Collections.Generic.List[string]][IO.File]::ReadAllLines($settingsPath)
$section = $settings.IndexOf('[Rainmeter]')
if ($section -lt 0) { throw 'Rainmeter.ini has no [Rainmeter] section.' }
$settings.InsertRange($section + 1, [string[]]@('Logging=1', 'DisableAutoUpdate=1'))
$settings.AddRange([string[]]@('', '[SmokeTest]', 'Active=1', 'WindowX=20', 'WindowY=20'))
[IO.File]::WriteAllLines($settingsPath, $settings, [Text.Encoding]::Unicode)

# --- Run it -----------------------------------------------------------------------------------

$pluginRejected = [regex]::Escape('"NotArm64.dll" is not an ARM64 DLL')
$expected = [ordered]@{
	'version banner' = 'Rainmeter \d+\.\d+\.\d+\.\d+ \(ARM64\)'
	'built-in measures' = [regex]::Escape('SMOKETEST measures os_bits=64 calc=42 script=42')
	'Lua script' = [regex]::Escape('SMOKETEST lua sum=300000 format=3.142|00042|xxx integer=9.007199254741e+15 sort=1,3,5,9 gsub=a<1>b<2>c<3> pcall=false:boom:false:false coroutine=2,11 vararg=3 option=ok config=SmokeTest')
}
if ($hasForeignPlugin) {
	$expected['x86 plugin rejected'] = $pluginRejected
}

$logPath = Join-Path $root 'Rainmeter.log'
Write-Host "Starting $exe"
$process = Start-Process -FilePath $exe -WorkingDirectory $root -PassThru

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
	Start-Sleep -Milliseconds 500
	$log = Read-SharedFile $logPath
	$missing = @($expected.GetEnumerator() | Where-Object { $log -notmatch $_.Value } | ForEach-Object { $_.Key })
} while ($missing.Count -gt 0 -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline)

foreach ($name in $missing) {
	$failures.Add("Not found in the log: $name")
}

$machine = 'unknown'
if ($process.HasExited) {
	$failures.Add("Rainmeter.exe exited on its own with code $($process.ExitCode)")
} else {
	$information = [RainmeterSmokeTest.Native+ProcessMachineInformation]::new()
	if ([RainmeterSmokeTest.Native]::GetProcessInformation($process.Handle, $processMachineTypeInfo, [ref]$information, 8)) {
		$machine = '{0:X4}' -f $information.ProcessMachine
		if ($information.ProcessMachine -ne $imageFileMachineArm64) {
			$failures.Add("Rainmeter.exe runs as a $machine process, not as a native ARM64 (AA64) one")
		}
	} else {
		$failures.Add('GetProcessInformation() failed for Rainmeter.exe')
	}

	# The x86 and x64 emulators live in xtajit*.dll, which a native process has no use for.
	try {
		$process.Refresh()
		$modules = @($process.Modules | ForEach-Object { $_.ModuleName })
		$emulators = @($modules | Where-Object { $_ -match '^xtajit' })
		if ($emulators.Count -gt 0) {
			$failures.Add("Rainmeter.exe has an emulator loaded: $($emulators -join ', ')")
		}
		if ($modules -notcontains 'Rainmeter.dll') {
			$failures.Add('Rainmeter.exe has not loaded Rainmeter.dll')
		}
		Write-Host "Rainmeter.exe has $($modules.Count) modules loaded, none of them an emulator."
	} catch {
		Write-Host "Could not list the modules of Rainmeter.exe: $($_.Exception.Message)"
	}

	# Give the skins a moment to draw.
	Start-Sleep -Seconds 2
	Save-Screenshot (Join-Path $results 'Desktop.png')

	Start-Process -FilePath $exe -ArgumentList '!Quit' -WorkingDirectory $root -Wait
	if (-not $process.WaitForExit(15000)) {
		$failures.Add('Rainmeter.exe did not exit after !Quit')
		Stop-Process -Id $process.Id -Force
	}
}

# --- Report -----------------------------------------------------------------------------------

# A portable installation keeps its skins and layouts next to Rainmeter.exe, set up on first start.
foreach ($file in 'Skins\illustro\Clock\Clock.ini', 'Skins\SmokeTest\SmokeTest.lua', 'Layouts\illustro default\Rainmeter.ini') {
	if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) {
		$failures.Add("Not set up on first start: $file")
	}
}

$log = Read-SharedFile $logPath
if ($log) {
	Copy-Item -LiteralPath $logPath -Destination $results
}

# The default skins and the test skin are expected to load without a single error, other than the
# plugin that is there to be rejected.
$errors = @($log -split '\r?\n' | Where-Object { $_ -match '^ERRO ' -and $_ -notmatch $pluginRejected })
foreach ($line in $errors) {
	$failures.Add("Rainmeter logged an error: $line")
}

$dumps = @(Get-ChildItem -LiteralPath (Join-Path $root 'Crashes') -Filter *.dmp -ErrorAction SilentlyContinue)
if ($dumps.Count -gt 0) {
	$failures.Add("Rainmeter wrote $($dumps.Count) crash dump(s)")
	$dumps | Copy-Item -Destination $results
}

Write-Host '::group::Rainmeter.log'
Write-Host $log
Write-Host '::endgroup::'

$found = @($expected.Keys | Where-Object { $missing -notcontains $_ })
Write-Host "Process machine: $machine"
Write-Host "Found in the log: $($found -join ', ')"

if ($env:GITHUB_STEP_SUMMARY) {
	$summary = @(
		'### Smoke test on Windows on ARM',
		'',
		"Rainmeter.exe ran as a ``$machine`` process.",
		''
	)
	$summary += $expected.Keys | ForEach-Object { "- $(if ($missing -contains $_) { ':x:' } else { ':white_check_mark:' }) $_" }
	$summary += $failures | ForEach-Object { "- :x: $_" }
	$summary -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}

if ($failures.Count -gt 0) {
	foreach ($failure in $failures) {
		Write-Host "::error title=Smoke test::$failure"
	}
	exit 1
}
Write-Host 'Rainmeter runs as a native ARM64 process and the test skin reported the expected results.'
