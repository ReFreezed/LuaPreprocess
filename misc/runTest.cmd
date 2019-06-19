@ECHO OFF
CD /D "%~dp0.."

IF NOT EXIST local  MD local

lua preprocess-cl.lua --debug --saveinfo=local/info.lua --data="Hello, world!" misc/test.lua2p
REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua --data="Hello, world!" misc/test.lua2p --linenumbers

REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua --data="Hello, world!" --outputpaths misc/test.lua2p local/test.output.lua
REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua --data="Hello, world!" --outputpaths misc/test.lua2p local/test.output.lua --linenumbers
