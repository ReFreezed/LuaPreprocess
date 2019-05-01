@ECHO OFF
CD /D "%~dp0.."

FOR /R examples %%G IN (*.lua2p) DO (
	ECHO. & ECHO Processing example '%%~nxG'...
	lua preprocess-cl.lua "%%G" --debug --silent
	lua "%%~dpnG.lua"
)

ECHO. & ECHO All examples finished!
