#!/bin/sh
_=[[
exec lua "$0" "$@"
]]
--[[============================================================
--=
--=  LuaPreprocess command line program
--=  by Marcus 'ReFreezed' Thunström
--=
--=  License: MIT (see the bottom of this file)
--=  Website: https://github.com/ReFreezed/LuaPreprocess
--=
--=  Tested with Lua 5.1, 5.2 and 5.3.
--=
--==============================================================

	Script usage:
		lua preprocess-cl.lua [options] [--] filepath1 [filepath2 ...]

	Options:
		--data="Any data."
			A string with any data. If the option is present then the value
			will be available through the global 'dataFromCommandLine' in the
			processed files (and the message handler, if you have one).

		--handler=pathToMessageHandler
			Path to a Lua file that's expected to return a function or a
			table of functions. If it returns a function then it will be
			called with various messages as it's first argument. If it's
			a table, the keys should be the message names and the values
			should be functions to handle the respective message.
			(See 'Handler messages' and misc/testHandler.lua)
			The file shares the same environment as the processed files.

		--linenumbers
			Add comments with line numbers to the output.

		--meta
			Output the metaprogram to a temporary file (*.meta.lua). Useful
			if an error happens in the metaprogram. This file is removed if
			there's no error and --debug isn't enabled.

		--outputextension=fileExtension
			Specify what file extension generated files should have. The
			default is "lua". If any input files end in .lua then you must
			specify another file extension.

		--saveinfo=pathToSaveProcessingInfoTo
			Processing information includes what files had any preprocessor
			code in them, and things like that. The format of the file is a
			lua module that returns a table. Search this file for 'SavedInfo'
			to see what information is saved.

		--silent
			Only print errors to the console.

		--debug
			Enable some preprocessing debug features. Useful if you want
			to inspect the generated metaprogram (*.meta.lua). (This also
			enables the --meta option.)

		--
			Stop options from being parsed further. Needed if you have
			paths starting with "-".

----------------------------------------------------------------

	Handler messages:

	"init"
		Sent before any other message.
		Arguments:
			paths: Array of file paths to process. Paths can be added or removed freely.

	"beforemeta"
		Sent before a file's metaprogram runs.
		Arguments:
			path: The file being processed.

	"aftermeta"
		Sent after a file's metaprogram has produced output (before the output is written to a file).
		Arguments:
			path: The file being processed.
			luaString: The produced Lua code. You can modify this and return the modified string.

	"filedone"
		Sent after a file has finished processing and the output written to file.
		Arguments:
			path: The file being processed.
			outputPath: Where the output of the metaprogram was written.
			info: Info about the processed file. (See 'ProcessInfo' in preprocess.lua)

	"fileerror"
		Sent if an error happens while processing a file (right before the program quits).
		Arguments:
			path: The file being processed.
			error: The error message.

--============================================================]]

local startTime  = os.time()
local startClock = os.clock()

local args = arg

local major, minor = _VERSION:match"Lua (%d+)%.(%d+)"
if not major then
	print("[LuaPreprocess] Warning: Could not detect Lua version.")
else
	major = tonumber(major)
	minor = tonumber(minor)
end
local IS_LUA_51          = (major == 5 and minor == 1)
local IS_LUA_52          = (major == 5 and minor == 2)
local IS_LUA_53          = (major == 5 and minor == 3)
local IS_LUA_51_OR_LATER = (major == 5 and minor >= 1) or (major ~= nil and major > 5)
local IS_LUA_52_OR_LATER = (major == 5 and minor >= 2) or (major ~= nil and major > 5)
local IS_LUA_53_OR_LATER = (major == 5 and minor >= 3) or (major ~= nil and major > 5)

if not args[0] then  error("Expected to run from the Lua interpreter.")  end
local pp = dofile((args[0]:gsub("[^/\\]+$", "preprocess.lua")))

-- From args:
local addLineNumbers     = false
local isDebug            = false
local outputExtension    = "lua"
local processingInfoPath = ""
local silent             = false
local outputMeta         = false
local customData         = nil

--==============================================================
--= Local Functions ============================================
--==============================================================
local errorline
local F, formatBytes, formatInt
local loadLuaFile
local printf, printfNoise

F = string.format
function formatBytes(n)
	if     n >= 1024*1024*1024 then
		return F("%.2f GB", n/(1024*1024*1024))
	elseif n >= 1024*1024 then
		return F("%.2f MB", n/(1024*1024))
	elseif n >= 1024 then
		return F("%.2f kB", n/(1024))
	elseif n == 1 then
		return F("1 byte", n)
	else
		return F("%d bytes", n)
	end
end
-- function formatInt(n)
-- 	return
-- 		F("%.0f", n)
-- 		:reverse()
-- 		:gsub("%d%d%d", "%0,")
-- 		:gsub(",$", ""):gsub(",%-$", "-")
-- 		:reverse()
-- end

function printf(s, ...)
	print(s:format(...))
end
printfNoise = printf

function errorline(err)
	print("Error: "..tostring(err))
	os.exit(1)
end

if IS_LUA_52_OR_LATER then
	function loadLuaFile(path, env)
		return loadfile(path, "bt", env)
	end
else
	function loadLuaFile(path, env)
		local mainChunk, err = loadfile(path)
		if not mainChunk then  return mainChunk, err  end

		if env then  setfenv(mainChunk, env)  end

		return mainChunk
	end
end

--==============================================================
--= Preprocessor Script ========================================
--==============================================================

io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

math.randomseed(os.time()) -- In case math.random() is used anywhere.
math.random() -- Must kickstart...

local processOptions     = true
local messageHandlerPath = ""
local paths              = {}

for _, arg in ipairs(args) do
	if processOptions and arg:find"^%-" then
		if arg == "--" then
			processOptions = false

		elseif arg:find"^%-%-handler=" then
			messageHandlerPath = arg:match"^%-%-handler=(.*)$"

		elseif arg == "--silent" then
			silent = true

		elseif arg == "--linenumbers" then
			addLineNumbers = true

		elseif arg == "--debug" then
			isDebug    = true
			outputMeta = true

		elseif arg:find"^%-%-saveinfo=" then
			processingInfoPath = arg:match"^%-%-saveinfo=(.*)$"

		elseif arg:find"^%-%-outputextension=" then
			outputExtension = arg:match"^%-%-outputextension=(.*)$"

		elseif arg:find"^%-%-data=" then
			customData = arg:match"^%-%-data=(.*)$"

		elseif arg == "--meta" then
			outputMeta = true

		else
			errorline("Unknown option '"..arg.."'.")
		end

	else
		table.insert(paths, arg)
	end
end

if silent then
	printfNoise = function()end
end

local header = "= LuaPreprocess v"..pp.VERSION..os.date(", %Y-%m-%d %H:%M:%S =", startTime)
printfNoise(("="):rep(#header))
printfNoise("%s", header)
printfNoise(("="):rep(#header))



-- Prepare metaEnvironment.
pp.metaEnvironment.dataFromCommandLine = customData -- May be nil.



-- Load message handler.
local messageHandler = nil

local function sendMessage(message, ...)
	if not messageHandler then
		return

	elseif type(messageHandler) == "function" then
		local returnValues = pp.pack(messageHandler(message, ...))
		return unpack(returnValues, 1, returnValues.n)

	elseif type(messageHandler) == "table" then
		local _messageHandler = messageHandler[message]
		if not _messageHandler then  return  end

		local returnValues = pp.pack(_messageHandler(...))
		return unpack(returnValues, 1, returnValues.n)

	else
		assert(false)
	end
end

if messageHandlerPath ~= "" then
	-- Make the message handler and the metaprogram share the same environment.
	-- This way the message handler can easily define globals that the metaprogram uses.
	local mainChunk, err = loadLuaFile(messageHandlerPath, pp.metaEnvironment)
	if not mainChunk then
		errorline("Could not load message handler: "..err)
	end

	messageHandler = mainChunk()

	if type(messageHandler) == "function" then
		-- void
	elseif type(messageHandler) == "table" then
		for message, _messageHandler in pairs(messageHandler) do
			if type(message) ~= "string" then
				errorline(messageHandlerPath..": Table of handlers must only contain messages as keys.")
			elseif type(_messageHandler) ~= "function" then
				errorline(messageHandlerPath..": Table of handlers must only contain functions as values.")
			end
		end
	else
		errorline(messageHandlerPath..": File did not return a function or table.")
	end
end

sendMessage("init", paths)

if not paths[1] then
	errorline("No path(s) specified.")
end

local pat = "%."..pp.escapePattern(outputExtension).."$"
for _, path in ipairs(paths) do
	if path:find(pat) then
		errorline(
			"Invalid path '"..path.."'. (Paths must not end with ."..outputExtension
			.." as those will be used as output paths. You can change extension with --outputextension.)"
		)
	end
end

-- :SavedInfo
local processingInfo = {
	date  = os.date("%Y-%m-%d %H:%M:%S", startTime),
	files = {},
}

local byteCount     = 0
local lineCount     = 0
local lineCountCode = 0
local tokenCount    = 0

for _, path in ipairs(paths) do
	local startClockForPath = os.clock()
	printfNoise("Processing '%s'...", path)

	local pathMeta = path:gsub("%.%w+$", "")..".meta.lua"
	local pathOut  = path:gsub("%.%w+$", "").."."..outputExtension

	if not outputMeta then
		pathMeta = nil
	end

	local info = pp.processFile{
		pathIn         = path,
		pathMeta       = pathMeta,
		pathOut        = pathOut,

		debug          = isDebug,
		addLineNumbers = addLineNumbers,

		onBeforeMeta = messageHandler and function()
			sendMessage("beforemeta", path)
		end,

		onAfterMeta = messageHandler and function(lua)
			local luaModified = sendMessage("aftermeta", path, lua)

			if type(luaModified) == "string" then
				lua = luaModified

			elseif luaModified ~= nil then
				local err = F(
					"%s: Message handler did not return a string for 'aftermeta'. (Got %s)",
					messageHandlerPath, type(luaModified)
				)
				print(F("Error @ %s", err))
				sendMessage("fileerror", path, err)
				os.exit(1)
			end

			return lua
		end,

		onDone = messageHandler and function(info)
			sendMessage("filedone", path, pathOut, info)
		end,

		onError = function(err)
			sendMessage("fileerror", path, err)
			os.exit(1)
		end,
	}

	byteCount     = byteCount+info.processedByteCount
	lineCount     = lineCount+info.lineCount
	lineCountCode = lineCountCode+info.linesOfCode
	tokenCount    = tokenCount+info.tokenCount

	if processingInfoPath ~= "" then

		-- :SavedInfo
		info.path = path -- See 'ProcessInfo' in preprocess.lua for what more 'info' contains.
		table.insert(processingInfo.files, info)

	end

	printfNoise("Processing '%s' successful! (%.3fs)", path, os.clock()-startClockForPath)
	printfNoise(("-"):rep(#header))
end

if processingInfoPath ~= "" then
	printfNoise("Saving processing info to '%s'.", processingInfoPath)

	local luaParts = {"return"}
	assert(pp.serialize(luaParts, processingInfo))
	local lua = table.concat(luaParts)

	local file = assert(io.open(processingInfoPath, "wb"))
	file:write(lua)
	file:close()
end

printfNoise(
	"All done! (%.3fs, %.0f file%s, %.0f LOC, %.0f line%s, %.0f token%s, %s)",
	os.clock()-startClock,
	#paths,     #paths     == 1 and "" or "s",
	lineCountCode,
	lineCount,  lineCount  == 1 and "" or "s",
	tokenCount, tokenCount == 1 and "" or "s",
	formatBytes(byteCount)
)

--[[!===========================================================

Copyright © 2018-2019 Marcus 'ReFreezed' Thunström

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

==============================================================]]
