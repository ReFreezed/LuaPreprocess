@ECHO OFF
CD /D "%~dp0.."

IF NOT EXIST local  MD local

lua preprocess-cl.lua --debug --saveinfo=local/info.lua misc/test.lua2p
REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua misc/test.lua2p --linenumbers
