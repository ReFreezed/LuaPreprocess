@ECHO OFF
CD /D "%~dp0.."

SETLOCAL EnableDelayedExpansion
SET _fails=0

FOR /R examples %%G IN (*.lua2p) DO (
	ECHO. & ECHO Processing example '%%~nxG'...
	lua ./preprocess-cl.lua "%%G" --debug --silent
	IF !ERRORLEVEL! EQU 0 ( lua "%%~dpnG.lua" ) ELSE ( SET /A "_fails=!_fails!+1" )
)

ECHO.
IF %_fails% EQU 0 ( ECHO Finished examples successfully. ) ELSE ( ECHO Finished examples with %_fails% failures. )
