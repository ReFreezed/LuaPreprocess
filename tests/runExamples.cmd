@ECHO OFF
REM $ runExamples.cmd [luaExePath]
REM Default value for luaExePath is "lua".

SETLOCAL EnableDelayedExpansion

REM Prepare Lua command.
SET _lua=%1
SET _luaExt=%~1
SET _luaExt=%_luaExt:~-4%
IF [%_lua%]==[] ( SET _lua=lua & SET "_luaExt=" )
REM Use CALL if the Lua command is a Batch file, because Windows is annoying.
IF /I "%_luaExt%"==".cmd"  SET _lua=CALL %_lua%
IF /I "%_luaExt%"==".bat"  SET _lua=CALL %_lua%

REM Prepare folders.
CD /D "%~dp0.."



ECHO Running examples...
SET _fails=0

FOR /R examples %%G IN (*.lua2p) DO (
	ECHO. & ECHO Processing example '%%~nxG'...
	%_lua% ./preprocess-cl.lua "%%G" --debug --silent
	IF !ERRORLEVEL! EQU 0 ( %_lua% -e"io.stdout:setvbuf'no' io.stderr:setvbuf'no'" "%%~dpnG.lua" ) ELSE ( SET /A "_fails=_fails+1" )
)
ECHO.

IF %_fails% EQU 0 (
	ECHO Finished examples successfully.
) ELSE (
	ECHO Finished examples with %_fails% failures.
	EXIT /B 1
)
