## Building Rainmeter

### Get the source code

Use <a href="http://git-scm.com">Git</a> to clone the repository:

    git clone https://github.com/rainmeter/rainmeter.git

Alternatively, download the repository contents as a [ZIP archive](https://github.com/rainmeter/rainmeter/archive/master.zip).


### Building with Visual Studio

Install the required tools:

- [Visual Studio Community 2026](https://www.visualstudio.com/downloads/) (select "Desktop development with C++" in the installer)
- [.NET Framework 4.7.1 Developer Pack](https://dotnet.microsoft.com/en-us/download/dotnet-framework/thank-you/net471-developer-pack-offline-installer)
- [NSIS 3](http://nsis.sourceforge.net)

Then open `Rainmeter.sln` to build and run Rainmeter.


### Building for Windows on ARM

Besides `x64`, the solution has two platforms for ARM64 devices. Both need the C++ ARM64/ARM64EC build tools component of Visual Studio.

- `ARM64EC` is ARM64 code that stays compatible with x64, so it can still load the x64 plugin DLLs that skins come with.
- `ARM64` contains no x64 code at all. It cannot load x64 DLLs, so only plugins that are themselves compiled for ARM64 work with it.

To build the native `ARM64` version, run the following in a Developer PowerShell for Visual Studio:

    MSBuild.exe Rainmeter.sln /p:Configuration=Release /p:Platform=ARM64 /m

The result is written to `BuildOut\ReleaseARM64`. The `build-arm64` GitHub Actions workflow runs the same build on every push to the default branch, or on demand, and uploads it as `Rainmeter-ARM64-Portable.zip`.


### Building the installer

Run the following PowerShell command, replacing `1.2.3.4` with the release version:

    .\Build\Build.ps1 full 1.2.3.4 -IncludeTests

For more control, check `Get-Help .\Build\Build.ps1 -Detailed` to see the available parameters.
