@ECHO OFF
REM $ runQuickTestUsingStd.cmd [luaExePath]
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
IF EXIST temp\stdout.txt  DEL temp\stdout.txt
IF EXIST temp\stderr.txt  DEL temp\stderr.txt



%_lua% ./preprocess-cl.lua --debug --data="Hello, world!" - <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt || EXIT /B 1
REM %_lua% ./preprocess-cl.lua --debug --data="Hello, world!" - --backtickstrings <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt || EXIT /B 1
REM %_lua% ./preprocess-cl.lua --debug --data="Hello, world!" - --linenumbers <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt || EXIT /B 1

REM %_lua% ./preprocess-cl.lua --debug --data="Hello, world!" --outputpaths - - <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt || EXIT /B 1
REM %_lua% ./preprocess-cl.lua --debug --data="Hello, world!" --outputpaths - - --linenumbers <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt || EXIT /B 1
