@echo off
rem One command builds the native accelerator on Windows, from a normal command prompt:
rem
rem     native\build.cmd
rem
rem It finds Visual Studio's build environment, makes sure the pinned godot-cpp is present,
rem and builds the release library into addons\pb_native\bin\ (git-ignored).
setlocal

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
	echo native: vswhere not found - install Visual Studio 2022 with the C++ workload.
	exit /b 1
)

for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH (
	echo native: no Visual Studio installation with the C++ workload found.
	exit /b 1
)

call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

bash "%~dp0build.sh" %*
exit /b %ERRORLEVEL%
