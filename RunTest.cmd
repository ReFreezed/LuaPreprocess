@ECHO OFF
MKDIR Local
lua main.lua --debug --saveinfo=Local/info.lua test.lua2p
