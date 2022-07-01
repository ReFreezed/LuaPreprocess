@ECHO OFF
REM $ runQuickTestUsingHandler.cmd [luaExePath]
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



%_lua% ./preprocess-cl.lua --debug --saveinfo=temp/info.lua --handler=tests/quickTestHandlerTable.lua tests/quickTest.lua2p || EXIT /B 1
REM %_lua% ./preprocess-cl.lua --debug --saveinfo=temp/info.lua --handler=tests/quickTestHandlerTable.lua --outputpaths tests/quickTest.lua2p temp/quickTest.output.lua || EXIT /B 1

%_lua% ./preprocess-cl.lua --debug --saveinfo=temp/info.lua --handler=tests/quickTestHandlerFunction.lua tests/quickTest.lua2p || EXIT /B 1
REM %_lua% ./preprocess-cl.lua --debug --saveinfo=temp/info.lua --handler=tests/quickTestHandlerFunction.lua --outputpaths tests/quickTest.lua2p temp/quickTest.output.lua || EXIT /B 1

ECHO. & ECHO Running quickTest.lua...
%_lua% -e"io.stdout:setvbuf'no' io.stderr:setvbuf'no'" tests/quickTest.lua || EXIT /B 1
