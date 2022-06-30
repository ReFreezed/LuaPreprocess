@ECHO OFF
REM $ runQuickTestUsingApi.cmd [luaExePath]
REM Default value for luaExePath is "lua".

SETLOCAL

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
IF NOT EXIST temp  MD temp



%_lua% tests/runQuickTestUsingApi.lua || EXIT /B 1

%_lua% -e"io.stdout:setvbuf'no' io.stderr:setvbuf'no'" tests/quickTest.lua || EXIT /B 1
