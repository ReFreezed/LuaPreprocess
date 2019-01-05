@ECHO OFF

SET example=namedConstants
ECHO.
ECHO Running %example%...
lua main.lua examples\%example%.lua2p --debug --silent
lua          examples\%example%.lua

SET example=optimizeDataAccess
ECHO.
ECHO Running %example%...
lua main.lua examples\%example%.lua2p --debug --silent
lua          examples\%example%.lua

SET example=parseFile
ECHO.
ECHO Running %example%...
lua main.lua examples\%example%.lua2p --debug --silent
lua          examples\%example%.lua

SET example=selectiveFunctionality
ECHO.
ECHO Running %example%...
lua main.lua examples\%example%.lua2p --debug --silent
lua          examples\%example%.lua

ECHO.
ECHO All examples finished!
