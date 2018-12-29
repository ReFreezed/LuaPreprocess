@ECHO OFF

SET example=examples\namedConstants.lua
ECHO.
ECHO Running %example%...
lua main.lua %example%2p --debug --silent
lua          %example%

SET example=examples\parseFile.lua
ECHO.
ECHO Running %example%...
lua main.lua %example%2p --debug --silent
lua          %example%

SET example=examples\selectiveFunctionality.lua
ECHO.
ECHO Running %example%...
lua main.lua %example%2p --debug --silent
lua          %example%
