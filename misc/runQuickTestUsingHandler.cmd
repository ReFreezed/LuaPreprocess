@ECHO OFF
CD /D "%~dp0.."

IF NOT EXIST local  MD local

lua preprocess-cl.lua --debug --saveinfo=local/info.lua --handler=misc/quickTestHandler.lua misc/quickTest.lua2p
REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua --handler=misc/quickTestHandler.lua --outputpaths misc/quickTest.lua2p local/quickTest.output.lua

lua misc/quickTest.lua
