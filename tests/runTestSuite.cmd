@ECHO OFF
CD /D "%~dp0.."

IF NOT EXIST local  MD local

SET _lua=%1
IF [%_lua%]==[]  SET _lua=lua

%_lua% tests/suite.lua
