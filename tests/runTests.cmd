@ECHO OFF
CD /D "%~dp0.."

IF NOT EXIST local  MD local

lua tests/runTests.lua
