--[[============================================================
--=
--=  Lua preprocessor
--=  by Marcus 'ReFreezed' Thunström
--=
--=  License: MIT (see the bottom of this file)
--=  Website: https://github.com/ReFreezed/LuaPreprocess
--=
--=  Tested for Lua 5.1.
--=
--==============================================================

	Script usage:
		lua main.lua [--handler=pathToMessageHandler] [--silent] [--] path1 [path2...]

	Options:
		--handler  Path to a Lua file that's expected to return a function.
		           The function will be called with various messages as it's
		           first argument. (See 'Handler messages')
		--silent   Only print errors to the console.
		--         Stop options from being parsed further.

----------------------------------------------------------------

	-- Metaprogram example:

	-- Normal Lua.
	local n = 0
	doTheThing()

	-- Preprocessor lines.
	local n = 0
	!if math.random() < 0.5 then
		n = n+10 -- Normal Lua.
		-- Note: In the final program, this will be in the
		-- same scope as 'local n = 0' here above.
	!end

	!for i = 1, 3 do
		print("3 lines with print().")
	!end

	-- Preprocessor block.
	!(
	local dogWord = "Woof "
	function getDogText()
		return dogWord:rep(3)
	end
	)

	-- Preprocessor inline block. (Expression that returns a value.)
	local text = !("The dog said: "..getDogText())

	-- Beware in preprocessor blocks that only call a single function!
	!(func())  -- This will bee seen as an inline block and output whatever value func() returns (nil if nothing) as a literal.
	!(func();) -- If that's not wanted then a trailing ";" will prevent that. This line won't output anything by itself.
	-- When the full metaprogram is created, "!(func())" is translated into "outputValue(func())"
	-- while "!(func();)" is translated into simply "func();", because "outputValue(func();)" would be invalid Lua code.

----------------------------------------------------------------

	Global functions in metaprogram and message handler:
	- getFileContents, fileExists
	- printf
	- run
	Only in metaprogram:
	- outputValue, outputLua

	Search this file for 'MessageHandlerEnvironment' or 'MetaEnvironment' for more info.

----------------------------------------------------------------

	Handler messages:

	"init"
		Sent before any other message.
		Arguments:
			message: The name of this message.
			paths: Array of file paths to process. Paths can be added or removed freely.

	"beforemeta"
		Sent before a file's metaprogram runs.
		Arguments:
			message: The name of this message.
			path: What file is being processed.
			metaprogramEnvironment: Environment table that is used for the metaprogram (a new table for each file).

	"aftermeta"
		Sent after a file's metaprogram has produced output (before the output is written to a file).
		Arguments:
			message: The name of this message.
			path: What file was processed.
			lua: String with the produced Lua code. You can modify this and return the modified string.

	"filedone"
		Sent after a file has finished processing and the output written to file.
		Arguments:
			message: The name of this message.
			path: What file was processed.
			outputPath: Where the output of the metaprogram was written.

--============================================================]]

local VERSION = "1.0.0"

local KEYWORDS = {
	"and","break","do","else","elseif","end","false","for","function","if","in",
	"local","nil","not","or","repeat","return","then","true","until","while",
} for i, v in ipairs(KEYWORDS) do  KEYWORDS[v], KEYWORDS[i] = true, nil  end

local PUNCTUATION = {
	"+",  "-",  "*",  "/",  "%",  "^",  "#",
	"==", "~=", "<=", ">=", "<",  ">",  "=",
	"(",  ")",  "{",  "}",  "[",  "]",
	";",  ":",  ",",  ".",  "..", "...",
} for i, v in ipairs(PUNCTUATION) do  PUNCTUATION[v], PUNCTUATION[i] = true, nil  end

local ESCAPE_SEQUENCES = {
	["\a"] = [[\a]],
	["\b"] = [[\b]],
	["\f"] = [[\f]],
	["\n"] = [[\n]],
	["\r"] = [[\r]],
	["\t"] = [[\t]],
	["\v"] = [[\v]],
	["\\"] = [[\\]],
	["\""] = [[\"]],
	["\'"] = [[\']],
}

local ERROR_UNFINISHED_VALUE = 1

local silent = false

--==============================================================
--= Local Functions ============================================
--==============================================================
local assertarg
local concatTokens
local error, errorline, errorOnLine, errorInFile
local F
local getFileContents, fileExists
local parseStringlike
local printf, printfNoise, printTokens
local tokensizeLua

F = string.format

function printf(s, ...)
	print(s:format(...))
end
function printfNoise(s, ...)
	if not silent then  printf(s, ...)  end
end
function printTokens(tokens, filter)
	for i, tok in ipairs(tokens) do
		if not (filter and (tok.type == "whitespace" or tok.type == "comment")) then
			printf("%d  %-12s '%s'", i, tok.type, (F("%q", tostring(tok.value)):sub(2, -2):gsub("\\\n", "\\n")))
		end
	end
end

function error(err, level)
	print(debug.traceback("Error: "..tostring(err), (level or 1)+1))
	os.exit(1)
end
function errorline(err)
	print("Error: "..tostring(err))
	os.exit(1)
end
function errorOnLine(path, ln, agent, s, ...)
	if agent then
		printf(
			"Error @ %s:%d: [%s] %s",
			path, ln, agent, s:format(...)
		)
	else
		printf(
			"Error @ %s:%d: %s",
			path, ln, s:format(...)
		)
	end
	os.exit(1)
end
function errorInFile(contents, path, ptr, agent, s, ...)
	local pre = contents:sub(1, ptr-1)

	local lastLine1 = pre:reverse():match"^[^\r\n]*":reverse():gsub("\t", "    ")
	local lastLine2 = contents:match("^[^\r\n]*", ptr):gsub("\t", "    ")
	local lastLine  = lastLine1..lastLine2

	local _, nlCount = pre:gsub("\n", "%0")
	local ln = nlCount+1

	local col = #lastLine1+1

	if agent then
		printf(
			"Error @ %s:%d: [%s] %s\n> \n> %s\n> %s^\n>",
			path, ln, agent, s:format(...), lastLine, ("-"):rep(col-1)
		)
	else
		printf(
			"Error @ %s:%d: %s\n> \n> %s\n> %s^\n>",
			path, ln, s:format(...), lastLine, ("-"):rep(col-1)
		)
	end
	os.exit(1)
end

function parseStringlike(s, ptr)
	local reprStart = ptr
	local reprEnd

	local valueStart
	local valueEnd

	local longEqualSigns = s:match("^%[(=*)%[", ptr)
	local isLong = (longEqualSigns ~= nil)

	-- Single line.
	if not isLong then
		valueStart = ptr

		local i1, i2 = s:find("\r?\n", ptr)
		if not i1 then
			reprEnd  = #s
			valueEnd = #s
			ptr      = reprEnd+1
		else
			reprEnd  = i2
			valueEnd = i1-1
			ptr      = reprEnd+1
		end

	-- Multiline.
	else
		ptr        = ptr+1+#longEqualSigns+1
		valueStart = ptr

		local i1, i2 = s:find("%]"..longEqualSigns.."%]", ptr)
		if not i1 then
			return nil, ERROR_UNFINISHED_VALUE
		end

		reprEnd  = i2
		valueEnd = i1-1
		ptr      = reprEnd+1
	end

	local repr = s:sub(reprStart,  reprEnd)
	local v    = s:sub(valueStart, valueEnd)
	local tok  = {type="stringlike", representation=repr, value=v, long=isLong}

	return tok, ptr
end

function tokensizeLua(s, path)
	local tokens = {}
	local ptr    = 1

	while ptr <= #s do
		local tok
		local tokenPos = ptr

		-- Identifier/keyword.
		if s:find("^[%a_]", ptr) then
			local i1, i2, word = s:find("^([%a_][%w_]*)", ptr)
			ptr = i2+1

			if KEYWORDS[word] then
				tok = {type="keyword",    representation=word, value=word}
			else
				tok = {type="identifier", representation=word, value=word}
			end

		-- Number.
		elseif s:find("^%.?%d", ptr) then
			local           i1, i2, numStr = s:find("^(%d*%.%d+[Ee]%-?%d+)", ptr)
			if not i1 then  i1, i2, numStr = s:find("^(%d+[Ee]%-?%d+)",      ptr)  end
			if not i1 then  i1, i2, numStr = s:find("^(0x[%dA-Fa-f]+)",      ptr)  end
			if not i1 then  i1, i2, numStr = s:find("^(%d*%.%d+)",           ptr)  end
			if not i1 then  i1, i2, numStr = s:find("^(%d+)",                ptr)  end

			if not i1 then
				errorInFile(s, path, ptr, "Tokenizer", "Malformed number.")
			end

			local n = tonumber(numStr)
			if not n then
				errorInFile(s, path, ptr, "Tokenizer", "Invalid number.")
			end

			ptr = i2+1
			tok = {type="number", representation=numStr, value=n}

		-- Comment.
		elseif s:find("^%-%-", ptr) then
			local reprStart = ptr
			ptr = ptr+2

			tok, ptr = parseStringlike(s, ptr)
			if not tok then
				if ptr == ERROR_UNFINISHED_VALUE then
					errorInFile(s, path, reprStart, "Tokenizer", "Unfinished long comment.")
				else
					errorInFile(s, path, reprStart, "Tokenizer", "Invalid comment.")
				end
			end

			tok.type           = "comment"
			tok.representation = s:sub(reprStart, ptr-1)

		-- String (short).
		elseif s:find([=[^["']]=], ptr) then
			local reprStart = ptr
			local reprEnd

			local quoteChar = s:sub(ptr, ptr)
			ptr = ptr+1

			local valueStart = ptr
			local valueEnd

			while true do
				local c = s:sub(ptr, ptr)

				if c == "" then
					errorInFile(s, path, reprStart, "Tokenizer", "Unfinished string.")

				elseif c == quoteChar then
					reprEnd  = ptr
					valueEnd = ptr-1
					ptr      = reprEnd+1
					break

				elseif c == "\\" then
					-- Note: We don't have to look for multiple characters after
					-- the escape, like \nnn - this algorithm works anyway.
					if ptr+1 > #s then
						errorInFile(s, path, reprStart, "Tokenizer", "Unfinished string after escape.")
					end
					ptr = ptr+2

				else
					ptr = ptr+1
				end
			end

			local repr = s:sub(reprStart, reprEnd)

			local valueChunk = loadstring("return"..repr)
			if not valueChunk then
				errorInFile(s, path, reprStart, "Tokenizer", "Malformed string.")
			end

			local v = valueChunk()
			assert(type(v) == "string")

			tok = {type="string", representation=repr, value=valueChunk(), long=false}

		-- Long string.
		elseif s:find("^%[=*%[", ptr) then
			local reprStart = ptr

			tok, ptr = parseStringlike(s, ptr)
			if not tok then
				if ptr == ERROR_UNFINISHED_VALUE then
					errorInFile(s, path, reprStart, "Tokenizer", "Unfinished long string.")
				else
					errorInFile(s, path, reprStart, "Tokenizer", "Invalid long string.")
				end
			end

			local valueChunk = loadstring("return"..tok.representation)
			if not valueChunk then
				errorInFile(s, path, reprStart, "Tokenizer", "Malformed long string.")
			end

			local v = valueChunk()
			assert(type(v) == "string")

			tok.type  = "string"
			tok.value = v

		-- Whitespace.
		elseif s:find("^%s", ptr) then
			local i1, i2, whitespace = s:find("^(%s+)", ptr)

			ptr = i2+1
			tok = {type="whitespace", representation=whitespace, value=whitespace}

		-- Punctuation etc.
		elseif s:find("^%.%.%.", ptr) then
			local repr = s:sub(ptr, ptr+2)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr
		elseif s:find("^%.%.", ptr) or s:find("^[=~<>]=", ptr) then
			local repr = s:sub(ptr, ptr+1)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr
		elseif s:find("^[+%-*/%%^#<>=(){}[%];:,.]", ptr) then
			local repr = s:sub(ptr, ptr)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr

		-- Preprocessor: Entry.
		elseif s:find("^!", ptr) then
			local repr = s:sub(ptr, ptr)
			tok = {type="pp_entry", representation=repr, value=repr}
			ptr = ptr+#repr

		else
			errorInFile(s, path, ptr, "Tokenizer", "Unknown character.")
		end

		tok.position = tokenPos
		table.insert(tokens, tok)
		-- print(#tokens, tok.type, tok.representation)
	end

	return tokens
end

function concatTokens(tokens)
	local parts = {}
	for i, tok in ipairs(tokens) do
		parts[i] = tok.representation
	end
	return table.concat(parts)
end

function getFileContents(path, isTextFile)
	assertarg(1, path,       "string")
	assertarg(2, isTextFile, "boolean","nil")

	local file, err = io.open(path, "r"..(isTextFile and "" or "b"))
	if not file then  return nil, err  end

	local contents = file:read"*a"
	file:close()
	return contents
end
function fileExists(path)
	assertarg(1, path, "string")

	local file = io.open(path, "r")
	if not file then  return false  end

	file:close()
	return true
end

-- value = assertarg( [ functionName=auto, ] argumentNumber, value, expectedValueType... [, depth=2 ] )
do
	local function _assertarg(fName, n, v, ...)
		local vType       = type(v)
		local varargCount = select("#", ...)
		local lastArg     = select(varargCount, ...)
		local hasDepthArg = (type(lastArg) == "number")
		local typeCount   = varargCount+(hasDepthArg and -1 or 0)

		for i = 1, typeCount do
			if vType == select(i, ...) then  return v  end
		end

		local depth = 2+(hasDepthArg and lastArg or 2)

		if not fName then
			fName = debug.traceback("", depth-1):match": in function '(.-)'" or "?"
		end

		local expects = table.concat({...}, " or ", 1, typeCount)

		error(F("bad argument #%d to '%s' (%s expected, got %s)", n, fName, expects, vType), depth)
	end

	function assertarg(fNameOrArgNum, ...)
		if type(fNameOrArgNum) == "string" then
			return _assertarg(fNameOrArgNum, ...)
		else
			return _assertarg(nil, fNameOrArgNum, ...)
		end
	end
end

--==============================================================
--= Preprocessor Script ========================================
--==============================================================

io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

-- Parse script arguments.
local processOptions     = true
local messageHandlerPath = ""
local paths              = {}

for i = 1, select("#", ...) do
	local arg = select(i, ...)

	if processOptions and arg:find"^%-" then
		if arg == "--" then
			processOptions = false

		elseif arg:find"^%-%-handler=" then
			messageHandlerPath = arg:match"^%-%-handler=(.*)$"

		elseif arg == "--silent" then
			silent = true

		else
			errorline("Unknown")
		end

	else
		table.insert(paths, arg)
	end
end

local header = "= LuaPreprocess v"..VERSION..os.date", %Y-%m-%d %H:%M:%S ="
printfNoise(("="):rep(#header))
printfNoise("%s", header)
printfNoise(("="):rep(#header))

math.randomseed(os.time()) -- Just in case math.random() is used anywhere.
math.random() -- Must kickstart...

-- Load message handler.
local messageHandler = nil
if messageHandlerPath ~= "" then
	local chunk, err = loadfile(messageHandlerPath)
	if not chunk then
		errorline("Could not load message handler: "..err)
	end

	messageHandler = chunk()
	if type(messageHandler) ~= "function" then
		errorline(messageHandlerPath..": File did not return a message handler function.")
	end
end

-- Begin the real work!



-- :MessageHandlerEnvironment
-- The message handler simply shares our environment for now.

-- printf()
--   Print a formatted string.
--   printf( format, value1, ... )
_G.printf = printf

-- contents, error = getFileContents()
--   Get the entire contents of a binary file or text file. Return nil and a message on error.
--   getFileContents( path [, isTextFile=false ] )
_G.getFileContents = getFileContents

-- bool = fileExists()
--   Check if a file exists.
--   fileExists( path )
_G.fileExists = fileExists

-- run()
--   Execute a Lua file. Similar to dofile().
--   returnValue1, ... = run( path )
function _G.run(path)
	assertarg(1, path, "string")

	local chunk, err = loadfile(path)
	if not chunk then
		errorline(err)
	end

	return chunk()
end



if messageHandler then  messageHandler("init", paths)  end

if not paths[1] then
	errorline("No path(s) specified.")
end
for _, path in ipairs(paths) do
	if path:find"%.lua$" then
		errorline("Invalid path '"..path.."'. (Paths must not end with .lua as those will be used as output paths.)")
	end
end

for _, path in ipairs(paths) do
	printfNoise("Processing '%s'...", path)

	local file, err = io.open(path, "rb")
	if not file then
		errorline("Could not open file: "..err)
	end
	local luaUnprocessed = file:read"*a"
	file:close()

	local specialFirstLine, rest = luaUnprocessed:match"^(#[^\r\n]*\r?\n?)(.*)$"
	if specialFirstLine then
		luaUnprocessed = rest
	end

	local tokens = tokensizeLua(luaUnprocessed, path)

	-- Create metaprogram.
	--==============================================================

	local startOfLine     = true
	local isMeta          = false
	local tokensToProcess = {}
	local metaParts       = {}

	local function outputTokens(tokens)
		local lua     = concatTokens(tokens)
		local luaMeta = F("outputLua(%q)\n", lua)
		-- luaMeta = luaMeta:gsub("\\\n", "\\n") -- Debug.

		table.insert(metaParts, luaMeta)
	end

	local tokenIndex = 1
	while true do
		local tok = tokens[tokenIndex]
		if not tok then  break  end

		-- Meta code.
		--------------------------------
		if isMeta then
			if (tok.type == "whitespace" and tok.value:find("\n", 1, true)) or (tok.type == "comment" and not tok.long) then
				startOfLine = true
				isMeta      = false

				if tok.type == "comment" then
					table.insert(metaParts, tok.representation)
				else
					table.insert(metaParts, "\n")
				end

			elseif tok.type == "pp_entry" then
				errorInFile(luaUnprocessed, path, tok.position, "Parser", "Preprocessor token inside metaprogram.")

			else
				table.insert(metaParts, tok.representation)
			end

		-- Raw code.
		--------------------------------
		else
			-- Potential start of meta line. (Must be at the start of the line, possibly after whitespace.)
			if tok.type == "whitespace" or (tok.type == "comment" and not tok.long) then
				table.insert(tokensToProcess, tok)

				if not (tok.type == "whitespace" and not tok.value:find("\n", 1, true)) then
					startOfLine = true
				end

			-- Meta block. Examples:
			-- !( function sum(a, b) return a+b; end )
			-- local text = !("Hello, mr. "..getName())
			elseif
				tok.type == "pp_entry"
				and tokens[tokenIndex+1]
				and tokens[tokenIndex+1].type == "punctuation"
				and tokens[tokenIndex+1].value == "("
			then
				local startPos = tok.position
				tokenIndex = tokenIndex+2 -- Jump past "!(".

				if tokensToProcess[1] then
					outputTokens(tokensToProcess)
					tokensToProcess = {}
				end

				local tokensInBlock = {}
				local depth         = 1

				while true do
					tok = tokens[tokenIndex]
					if not tok then
						errorInFile(luaUnprocessed, path, startPos, "Parser", "Missing end of meta block.")
					end

					if tok.type == "punctuation" and tok.value == "(" then
						depth = depth+1

					elseif tok.type == "punctuation" and tok.value == ")" then
						depth = depth-1
						if depth == 0 then  break  end

					elseif tok.type == "pp_entry" then
						errorInFile(luaUnprocessed, path, tok.position, "Parser", "Preprocessor token inside metaprogram.")
					end

					table.insert(tokensInBlock, tok)
					tokenIndex = tokenIndex+1
				end

				local metaBlock = concatTokens(tokensInBlock)

				if loadstring("return("..metaBlock..")") then
					table.insert(metaParts, "outputValue(")
					table.insert(metaParts, metaBlock)
					table.insert(metaParts, ")\n")
				else
					table.insert(metaParts, metaBlock)
					table.insert(metaParts, "\n")
				end

			-- Meta line. Example:
			-- !for i = 1, 3 do
			--    print("Marco. Polo.")
			-- !end
			elseif startOfLine and tok.type == "pp_entry" then
				isMeta      = true
				startOfLine = false

				if tokensToProcess[1] then
					outputTokens(tokensToProcess)
					tokensToProcess = {}
				end

			elseif tok.type == "pp_entry" then
				errorInFile(luaUnprocessed, path, tok.position, "Parser", "Unexpected preprocessor token.")

			else
				table.insert(tokensToProcess, tok)
				startOfLine = false
			end
		end
		--------------------------------

		tokenIndex = tokenIndex+1
	end

	if tokensToProcess[1] then
		outputTokens(tokensToProcess)
		tokensToProcess = {}
	end

	-- Run metaprogram.
	--==============================================================

	local pathMeta = path:gsub("%.%w+$", "")..".meta.lua"
	local luaParts = {}

	local metaEnv = {}
	for k, v in pairs(_G) do  metaEnv[k] = v  end
	metaEnv._G = metaEnv



	-- :MetaEnvironment

	-- See 'MessageHandlerEnvironment' more info about these:
	metaEnv.fileExists      = fileExists
	metaEnv.getFileContents = getFileContents
	metaEnv.printf          = printf

	function metaEnv.run(path)
		local chunk, err = loadfile(path)
		if not chunk then
			errorline(err)
		end

		setfenv(chunk, metaEnv)
		return (chunk())
	end

	-- outputValue()
	--   Output a value, like a string or table, as a literal.
	--   outputValue( value )
	function metaEnv.outputValue(v)
		local level = 2

		local function doOutputValue(v)
			level = level+1
			local vType = type(v)

			if vType == "table" then
				for k, item in pairs(v) do
					if type(k) == "table" then
						local ln = debug.getinfo(level, "l").currentline
						errorOnLine(pathMeta, ln, "MetaProgram", "Table keys cannot be tables.")
					end
					table.insert(luaParts, "[")
					doOutputValue(k)
					table.insert(luaParts, "]=")
					doOutputValue(item)
					table.insert(luaParts, ",")
				end

			elseif vType == "string" then
				table.insert(luaParts, (F("%q", v):gsub("\\\n", "\\n")))

			elseif v == math.huge then
				table.insert(luaParts, "math.huge")
			elseif v == -math.huge then
				table.insert(luaParts, " -math.huge") -- Prevent an accidental comment if there's a "-" right before.
			elseif v ~= v then
				table.insert(luaParts, "0/0") -- NaN.
			elseif v == 0 then
				table.insert(luaParts, "0") -- In case it's actually -0 for some reason, which would be silly to output.
			elseif vType == "number" then
				if v < 0 then
					table.insert(luaParts, " ") -- Prevent an accidental comment if there's a "-" right before.
				end
				table.insert(luaParts, tostring(v)) -- (I'm not sure what precision tostring() uses for numbers. Maybe we should use string.format() instead.)

			elseif vType == "boolean" or v == nil then
				table.insert(luaParts, tostring(v))

			else
				local ln = debug.getinfo(level, "l").currentline
				errorOnLine(pathMeta, ln, "MetaProgram", "Cannot output value of type '%s'. (%s)", vType, tostring(v))
			end
			level = level-1
		end

		doOutputValue(v)
	end

	-- outputLua()
	--   Output Lua code as-is.
	--   outputLua( luaCode )
	function metaEnv.outputLua(lua)
		assertarg(1, lua, "string")
		table.insert(luaParts, lua)
	end



	local luaMeta = table.concat(metaParts)
	--[[ :PrintCode
	print("=META===============================")
	print(luaMeta)
	print("====================================")
	--]]

	local file = assert(io.open(pathMeta, "wb"))
	file:write(luaMeta)
	file:close()

	local chunk, err = loadstring(luaMeta, "")
	if not chunk then
		local ln, err = err:match'^%[string ""%]:(%d+): (.*)'
		errorOnLine(pathMeta, tonumber(ln), nil, "%s", err)
	end
	setfenv(chunk, metaEnv)

	if messageHandler then  messageHandler("beforemeta", path, metaEnv)  end

	xpcall(chunk, function(err0)
		local ln, err = err0:match'^%[string ""%]:(%d+): (.*)'
		if err then
			errorOnLine(pathMeta, tonumber(ln), nil, "%s", err)
		else
			error(err0, 2)
		end
	end)

	os.remove(pathMeta)

	local lua = table.concat(luaParts)
	--[[ :PrintCode
	print("=OUTPUT=============================")
	print(lua)
	print("====================================")
	--]]

	if messageHandler then
		local luaModified = messageHandler("aftermeta", path, lua)

		if type(luaModified) == "string" then
			lua = luaModified
		elseif luaModified ~= nil then
			errorline("Message handler did not return a string for 'aftermeta'. (Got "..type(luaModified)..")")
		end
	end

	-- Write output file.
	----------------------------------------------------------------

	local pathOut = path:gsub("%.%w+$", "")..".lua"
	local file    = assert(io.open(pathOut, "wb"))
	file:write(specialFirstLine or "")
	file:write(lua)
	file:close()

	-- Test if the output is valid Lua.
	local chunk, err = loadstring(lua, "")
	if not chunk then
		local ln, err = err:match'^%[string ""%]:(%d+): (.*)'
		errorOnLine(pathOut, tonumber(ln), nil, "%s", err)
	end

	if messageHandler then  messageHandler("filedone", path, pathOut)  end

	printfNoise("Processing '%s'... done!", path)
	printfNoise(("-"):rep(#header))
end

printfNoise("All done!")

--[[!===========================================================

Copyright © 2018 Marcus 'ReFreezed' Thunström

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
