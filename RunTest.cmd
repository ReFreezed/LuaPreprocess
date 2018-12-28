@ECHO OFF
IF NOT EXIST local  MD local
lua main.lua --debug --saveinfo=local/info.lua test.lua2p
