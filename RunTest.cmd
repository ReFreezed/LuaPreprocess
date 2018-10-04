@ECHO OFF
IF NOT EXIST Local  MD Local
lua main.lua --debug --saveinfo=Local/info.lua test.lua2p
