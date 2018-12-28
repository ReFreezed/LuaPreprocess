@ECHO OFF

SET example=examples\parseFile.lua
ECHO.
ECHO Running %example%...
lua main.lua %example%2p --debug --silent
lua          %example%
