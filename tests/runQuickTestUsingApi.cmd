@ECHO OFF
CD /D "%~dp0.."

IF NOT EXIST local  MD local

lua tests/runQuickTestUsingApi.lua

IF %ERRORLEVEL% EQU 0  lua tests/quickTest.lua
