@ECHO OFF
CD /D "%~dp0.."

SETLOCAL EnableDelayedExpansion

FOR /R examples %%G IN (*.lua2p) DO (
	ECHO. & ECHO Processing example '%%~nxG'...
	lua preprocess-cl.lua "%%G" --debug --silent
	IF !ERRORLEVEL! EQU 0  lua "%%~dpnG.lua"
)

ECHO. & ECHO All examples finished!
