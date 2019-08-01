@ECHO OFF
CD /D "%~dp0.."

lua misc/runTests.lua
