@ECHO OFF
IF NOT EXIST local  MD local
lua preprocess-cl.lua --debug --saveinfo=local/info.lua test.lua2p
REM lua preprocess-cl.lua --debug --saveinfo=local/info.lua test.lua2p --linenumbers
