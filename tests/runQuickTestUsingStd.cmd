@ECHO OFF
CD /D "%~dp0.."

IF NOT EXIST temp             MD  temp
IF EXIST     temp\stdout.txt  DEL temp\stdout.txt
IF EXIST     temp\stderr.txt  DEL temp\stderr.txt

lua ./preprocess-cl.lua --debug --data="Hello, world!" - <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt
REM lua ./preprocess-cl.lua --debug --data="Hello, world!" - --backtickstrings <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt
REM lua ./preprocess-cl.lua --debug --data="Hello, world!" - --linenumbers <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt

REM lua ./preprocess-cl.lua --debug --data="Hello, world!" --outputpaths - - <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt
REM lua ./preprocess-cl.lua --debug --data="Hello, world!" --outputpaths - - --linenumbers <tests\quickTest.lua2p 1>temp\stdout.txt 2>temp\stderr.txt
