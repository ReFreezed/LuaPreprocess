@ECHO OFF
CD /D "%~dp0.."

IF NOT EXIST local  MD local

lua preprocess-cl.lua --debug --saveinfo=local/info.lua --data="Hello, world!" misc/quickTest.lua2p
REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua --data="Hello, world!" misc/quickTest.lua2p --linenumbers

REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua --data="Hello, world!" --outputpaths misc/quickTest.lua2p local/quickTest.output.lua
REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua --data="Hello, world!" --outputpaths misc/quickTest.lua2p local/quickTest.output.lua --linenumbers

IF %ERRORLEVEL% EQU 0  lua misc/quickTest.lua
