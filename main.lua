--[[============================================================
--=
--=  LuaPreprocess
--=  by Marcus 'ReFreezed' Thunström
--=
--=  License: MIT (see the bottom of this file)
--=  Website: https://github.com/ReFreezed/LuaPreprocess
--=
--=  Tested for Lua 5.1.
--=
--==============================================================

	Script usage:
		lua main.lua [options] [--] path1 [path2 ...]

	Options:
		--handler=pathToMessageHandler
			Path to a Lua file that's expected to return a function.
			The function will be called with various messages as it's
			first argument. (See 'Handler messages')

		--linenumbers
			Add comments with line numbers to the output.

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
			to inspect the generated metaprogram (*.meta.lua).

		--
			Stop options from being parsed further. Needed if you have
			paths starting with "-".

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

	-- Extended preprocessor line. (Lines are consumed until brackets
	-- are balanced when the end of the line has been reached.)
	!newClass{
		name  = "Entity",
		props = {x=0, y=0},
	}

	-- Preprocessor block.
	!(
	local dogWord = "Woof "
	function getDogText()
		return dogWord:rep(3)
	end
	)

	-- Preprocessor inline block. (Expression that returns a value.)
	local text = !("The dog said: "..getDogText())

	-- Preprocessor inline block variant. (Expression that returns a Lua string.)
	_G.!!("myRandomGlobal"..math.random(5)) = 99

	-- Beware in preprocessor blocks that only call a single function!
	!(func())  -- This will bee seen as an inline block and output whatever value func() returns (nil if nothing) as a literal.
	!(func();) -- If that's not wanted then a trailing ";" will prevent that. This line won't output anything by itself.
	-- When the full metaprogram is generated, "!(func())" translates into "outputValue(func())"
	-- while "!(func();)" simply translates into "func();" (because "outputValue(func();)" would be invalid Lua code).
	-- Though in this specific case a preprocessor line would be nicer:
	!func()

----------------------------------------------------------------

	Global functions in metaprogram and message handler:
	- getFileContents, fileExists
	- printf
	- run
	- toLua
	Only in metaprogram:
	- outputValue, outputLua

	Search this file for 'EnvironmentTable' for more info.

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

local startTime  = os.time()
local startClock = os.clock()

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
	"!!", "!", -- For preprocessor.
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

local addLineNumbers     = false
local isDebug            = false
local outputExtension    = "lua"
local processingInfoPath = ""
local silent             = false

local remoteEnv          = nil

local isRunningMeta      = false
local currentMetaPath    = ""
local outputFromMeta     = nil

--==============================================================
--= Local Functions ============================================
--==============================================================
local assertarg
local concatTokens
local copyTable
local countString
local error, errorline, errorOnLine, errorInFile
local errorIfNotRunningMeta
local escapePattern
local F, formatInt, formatBytes
local getFileContents, fileExists
local isAny
local maybeOutputLineNumber
local pack
local parseStringlike
local printf, printfNoise, printTokens
local serialize, serializeToString
local tokensize

F = string.format
function formatInt(n)
	return
		F("%.0f", n)
		:reverse()
		:gsub("%d%d%d", "%0,")
		:gsub(",$", ""):gsub(",%-$", "-")
		:reverse()
end
function formatBytes(n)
	if     n >= 1024*1024*1024 then
		return F("%.2f GB", n/(1024*1024*1024))
	elseif n >= 1024*1024 then
		return F("%.2f MB", n/(1024*1024))
	elseif n >= 1024 then
		return F("%.2f kB", n/(1024))
	else
		return F("%d bytes", n)
	end
end

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
			"Error @ %s:%d: [%s] %s\n>\n> %s\n>%s^\n>",
			path, ln, agent, s:format(...), lastLine, ("-"):rep(col)
		)
	else
		printf(
			"Error @ %s:%d: %s\n>\n> %s\n> %s^\n>",
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

-- tokens = tokensize( lua, filepath )
-- token  = { type=tokenType, line=lineNumber, position=startBytePosition, representation=representation, value=value }
function tokensize(s, path)
	local tokens = {}
	local ptr    = 1
	local ln     = 1

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
			local double = s:find("^!", ptr+1) ~= nil
			local repr   = s:sub(ptr, ptr+(double and 1 or 0))
			tok = {type="pp_entry", representation=repr, value=repr, double=double}
			ptr = ptr+#repr

		else
			errorInFile(s, path, ptr, "Tokenizer", "Unknown character.")
		end

		tok.line     = ln
		tok.position = tokenPos

		ln = ln+countString(tok.representation, "\n", true)

		table.insert(tokens, tok)
		-- print(#tokens, tok.type, tok.representation)
	end

	return tokens
end

function concatTokens(tokens, lastLn)
	local parts = {}

	if addLineNumbers then
		for _, tok in ipairs(tokens) do
			lastLn = maybeOutputLineNumber(parts, tok, lastLn)
			table.insert(parts, tok.representation)
		end

	else
		for i, tok in ipairs(tokens) do
			parts[i] = tok.representation
		end
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
			return (_assertarg(fNameOrArgNum, ...))
		else
			return (_assertarg(nil, fNameOrArgNum, ...))
		end
	end
end

function countString(haystack, needle, plain)
	local count = 0
	local i     = 0
	local _

	while true do
		_, i = haystack:find(needle, i+1, plain)
		if not i then  return count  end

		count = count+1
	end
end

-- success, errorMessage = serialize( buffer, value )
function serialize(buffer, v)
	local vType = type(v)

	if vType == "table" then
		local first = true
		table.insert(buffer, "{")

		local indices = {}
		for i, item in ipairs(v) do
			if not first then  table.insert(buffer, ",")  end
			first = false

			local ok, err = serialize(buffer, item)
			if not ok then  return false, err  end

			indices[i] = true
		end

		local keys = {}
		for k, item in pairs(v) do
			if indices[k] then
				-- void
			elseif type(k) == "table" then
				return false, "Table keys cannot be tables."
			else
				table.insert(keys, k)
			end
		end

		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)

		for _, k in ipairs(keys) do
			local item = v[k]

			if not first then  table.insert(buffer, ",")  end
			first = false

			if not KEYWORDS[k] and type(k) == "string" and k:find"^[%a_][%w_]*$" then
				table.insert(buffer, k)
				table.insert(buffer, "=")

			else
				table.insert(buffer, "[")

				local ok, err = serialize(buffer, k)
				if not ok then  return false, err  end

				table.insert(buffer, "]=")
			end

			local ok, err = serialize(buffer, item)
			if not ok then  return false, err  end
		end

		table.insert(buffer, "}")

	elseif vType == "string" then
		local s = F("%q", v)
		if isDebug then
			s = s:gsub("\\\n", "\\n")
		end
		table.insert(buffer, s)

	elseif v == math.huge then
		table.insert(buffer, "math.huge")
	elseif v == -math.huge then
		table.insert(buffer, " -math.huge") -- The space prevents an accidental comment if a "-" is right before.
	elseif v ~= v then
		table.insert(buffer, "0/0") -- NaN.
	elseif v == 0 then
		table.insert(buffer, "0") -- In case it's actually -0 for some reason, which would be silly to output.
	elseif vType == "number" then
		if v < 0 then
			table.insert(buffer, " ") -- The space prevents an accidental comment if a "-" is right before.
		end
		table.insert(buffer, tostring(v)) -- (I'm not sure what precision tostring() uses for numbers. Maybe we should use string.format() instead.)

	elseif vType == "boolean" or v == nil then
		table.insert(buffer, tostring(v))

	else
		return false, F("Cannot serialize value of type '%s'. (%s)", vType, tostring(v))
	end
	return true
end

-- luaString, errorMessage = serializeToString( value )
function serializeToString(v)
	local buffer = {}

	local ok, err = serialize(buffer, v)
	if not ok then  return nil, err  end

	return table.concat(buffer)
end

function escapePattern(s)
	return (s:gsub("[-+*^?$.%%()[%]]", "%%%0"))
end

function maybeOutputLineNumber(parts, tok, lastLn, fromMetaToOutput)
	if tok.line == lastLn or tok.type == "whitespace" or tok.type == "comment" then  return lastLn  end

	-- if fromMetaToOutput then
	-- 	table.insert(parts, '__LUA"--[[@'..tok.line..']]"\n')
	-- else
		table.insert(parts, "--[[@"..tok.line.."]]")
	-- end
	return tok.line
end

function isAny(v, ...)
	for i = 1, select("#", ...) do
		if v == select(i, ...) then  return true  end
	end
	return false
end

function errorIfNotRunningMeta(level)
	if not isRunningMeta then
		error("No file is being processed.", 1+level)
	end
end

-- copy = copyTable( table [, deep=false ] )
do
	local function deepCopy(t, copy, tableCopies)
		for k, v in pairs(t) do
			if type(v) == "table" then
				local vCopy = tableCopies[v]

				if vCopy then
					copy[k] = vCopy
				else
					vCopy          = {}
					tableCopies[v] = vCopy
					copy[k]        = deepCopy(v, vCopy, tableCopies)
				end

			else
				copy[k] = v
			end
		end
		return copy
	end

	function copyTable(t, deep)
		if deep then
			return deepCopy(t, {}, {})
		end

		local copy = {}
		for k, v in pairs(t) do  copy[k] = v  end

		return copy
	end
end

-- values = pack( value1, ... )
-- values.n is the amount of values. Values can be nil.
function pack(...)
	return {n=select("#", ...), ...}
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

for i = 1, select("#", ...) do
	local arg = select(i, ...)

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
			isDebug = true

		elseif arg:find"^%-%-saveinfo=" then
			processingInfoPath = arg:match"^%-%-saveinfo=(.*)$"

		elseif arg:find"^%-%-outputextension=" then
			outputExtension = arg:match"^%-%-outputextension=(.*)$"

		else
			errorline("Unknown option '"..arg.."'.")
		end

	else
		table.insert(paths, arg)
	end
end

local header = "= LuaPreprocess v"..VERSION..os.date(", %Y-%m-%d %H:%M:%S =", startTime)
printfNoise(("="):rep(#header))
printfNoise("%s", header)
printfNoise(("="):rep(#header))



-- :EnvironmentTable
remoteEnv = copyTable(_G, true) -- Include all standard Lua stuff.
remoteEnv._G = remoteEnv

-- printf()
--   Print a formatted string.
--   printf( format, value1, ... )
remoteEnv.printf = printf

-- getFileContents()
--   Get the entire contents of a binary file or text file. Return nil and a message on error.
--   contents, error = getFileContents( path [, isTextFile=false ] )
remoteEnv.getFileContents = getFileContents

-- fileExists()
--   Check if a file exists.
--   bool = fileExists( path )
remoteEnv.fileExists = fileExists

-- toLua()
--   Convert a value to a Lua literal. Does not work with certain types, like functions or userdata.
--   Returns nil and a message if an error ocurred.
--   luaString, errorMessage = toLua( value )
remoteEnv.toLua = serializeToString

-- run()
--   Execute a Lua file. Similar to dofile().
--   returnValue1, ... = run( path )
function remoteEnv.run(path)
	assertarg(1, path, "string")

	local chunk, err = loadfile(path)
	if not chunk then
		errorline(err)
	end
	setfenv(chunk, remoteEnv)

	-- We want multiple return values while avoiding a tail call to preserve stack info.
	local returnValues = pack(chunk())
	return unpack(returnValues, 1, returnValues.n)
end

-- outputValue()
--   Output one or more values, like strings or tables, as literals.
--   outputValue( value1, ... )
function remoteEnv.outputValue(...)
	errorIfNotRunningMeta(2)

	local argCount = select("#", ...)
	if argCount == 0 then
		error("No values to output.", 2)
		-- local ln = debug.getinfo(2, "l").currentline
		-- errorOnLine(currentMetaPath, ln, "MetaProgram", "No values to output.")
	end

	for i = 1, argCount do
		local v = select(i, ...)
		local ok, err = serialize(outputFromMeta, v)

		if not ok then
			local ln = debug.getinfo(2, "l").currentline
			errorOnLine(currentMetaPath, ln, "MetaProgram", "%s", err)
		end
	end
end

-- outputLua()
--   Output one or more strings as raw Lua code.
--   outputLua( luaString1, ... )
function remoteEnv.outputLua(...)
	errorIfNotRunningMeta(2)

	local argCount = select("#", ...)
	if argCount == 0 then
		error("No Lua code to output.", 2)
		-- local ln = debug.getinfo(2, "l").currentline
		-- errorOnLine(currentMetaPath, ln, "MetaProgram", "No Lua code to output.")
	end

	for i = 1, argCount do
		local lua = select(i, ...)
		assertarg(i, lua, "string")
		table.insert(outputFromMeta, lua)
	end
end



remoteEnv.__VAL = remoteEnv.outputValue
remoteEnv.__LUA = remoteEnv.outputLua

-- Load message handler.
local messageHandler = nil

if messageHandlerPath ~= "" then
	local chunk, err = loadfile(messageHandlerPath)
	if not chunk then
		errorline("Could not load message handler: "..err)
	end
	setfenv(chunk, remoteEnv)

	messageHandler = chunk()
	if type(messageHandler) ~= "function" then
		errorline(messageHandlerPath..": File did not return a message handler function.")
	end
	messageHandler("init", paths)
end

if not paths[1] then
	errorline("No path(s) specified.")
end

local pat = "%."..escapePattern(outputExtension).."$"
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

local byteCount  = 0
local lineCount  = 0
local tokenCount = 0

for _, path in ipairs(paths) do
	local startClockForPath = os.clock()
	printfNoise("Processing '%s'...", path)

	local file, err = io.open(path, "rb")
	if not file then
		errorline("Could not open file: "..err)
	end
	local luaUnprocessed = file:read"*a"
	file:close()

	byteCount = byteCount+#luaUnprocessed

	local specialFirstLine, rest = luaUnprocessed:match"^(#[^\r\n]*\r?\n?)(.*)$"
	if specialFirstLine then
		luaUnprocessed = rest
	end

	local tokens = tokensize(luaUnprocessed, path)

	if tokens[1] then
		local lastToken = tokens[#tokens]
		lineCount  = lineCount+lastToken.line+countString(lastToken.representation, "\n")
		tokenCount = tokenCount+#tokens
	end
	-- printTokens(tokens)

	-- Generate metaprogram.
	--==============================================================

	local hasPreprocessorCode = false

	for _, tok in ipairs(tokens) do
		if tok.type == "pp_entry" then
			hasPreprocessorCode = true
			break
		end
	end

	-- local startOfLine     = true
	local isMeta          = false
	local metaStartLine   = 0
	local bracketBalance  = 0

	local tokensToProcess = {}
	local metaParts       = {}

	local tokenIndex      = 1
	local ln              = 0

	local function outputTokens(tokens)
		if not tokens[1] then  return  end

		local lua = concatTokens(tokens, ln)
		local luaMeta

		if isDebug then
			luaMeta = F("__LUA(%q)\n", lua):gsub("\\\n", "\\n")
		else
			luaMeta = F("__LUA%q", lua)
		end

		table.insert(metaParts, luaMeta)
		ln = tokens[#tokens].line
	end

	while true do
		local tok = tokens[tokenIndex]
		if not tok then  break  end

		local tokType = tok.type

		-- Meta line (or lines if extended).
		--------------------------------
		if isMeta then
			if
				(
					(tokType == "whitespace" and tok.value:find("\n", 1, true))
					or (tokType == "comment" and not tok.long)
				)
				and bracketBalance == 0
			then
				-- startOfLine     = true
				isMeta          = false
				bracketBalance = 0

				if tokType == "comment" then
					table.insert(metaParts, tok.representation)
				else
					table.insert(metaParts, "\n")
				end

			elseif tokType == "pp_entry" then
				errorInFile(
					luaUnprocessed, path, tok.position, "Parser",
					"Preprocessor token inside metaprogram"
						..(tok.line == metaStartLine and "." or " (starting at line %d)."),
					metaStartLine
				)

			else
				table.insert(metaParts, tok.representation)

				if tokType == "punctuation" and isAny(tok.value, "(","{","[") then
					bracketBalance = bracketBalance+1
				elseif tokType == "punctuation" and isAny(tok.value, ")","}","]") then
					bracketBalance = bracketBalance-1

					if bracketBalance < 0 then
						errorInFile(
							luaUnprocessed, path, tok.position, "Parser",
							"Unexpected '%s'. Preprocessor line"
								..(tok.line == metaStartLine and "" or " (starting at line %d)")
								.." has unbalanced brackets.",
							tok.value, metaStartLine
						)
					end
				end
			end

		-- Meta block or start of meta line.
		--------------------------------

		-- Meta block. Examples:
		-- !( function sum(a, b) return a+b; end )
		-- local text = !("Hello, mr. "..getName())
		-- _G.!!("myRandomGlobal"..math.random(5)) = 99
		elseif
			tokType == "pp_entry"
			and tokens[tokenIndex+1]
			and tokens[tokenIndex+1].type == "punctuation"
			and tokens[tokenIndex+1].value == "("
		then
			local startToken  = tok
			local startPos    = tok.position
			local startLine   = tok.line
			local doOutputLua = tok.double
			tokenIndex = tokenIndex+2 -- Jump past "!(" or "!!(".

			if tokensToProcess[1] then
				outputTokens(tokensToProcess)
				tokensToProcess = {}
			end

			local tokensInBlock = {}
			local depth         = 1

			while true do
				tok = tokens[tokenIndex]
				if not tok then
					errorInFile(luaUnprocessed, path, startPos, "Parser", "Missing end of preprocessor block.")
				end

				tokType = tok.type

				if tokType == "punctuation" and tok.value == "(" then
					depth = depth+1

				elseif tokType == "punctuation" and tok.value == ")" then
					depth = depth-1
					if depth == 0 then  break  end

				elseif tokType == "pp_entry" then
					errorInFile(
						luaUnprocessed, path, tok.position, "Parser",
						"Preprocessor token inside metaprogram"..(tok.line == startLine and "." or " (starting at line %d)."),
						startLine
					)
				end

				table.insert(tokensInBlock, tok)
				tokenIndex = tokenIndex+1
			end

			local metaBlock = concatTokens(tokensInBlock)

			if loadstring("return("..metaBlock..")") then
				table.insert(metaParts, (doOutputLua and "__LUA(" or "__VAL("))
				table.insert(metaParts, metaBlock)
				table.insert(metaParts, ")\n")

			elseif doOutputLua then
				-- We could do something other than error here. Room for more functionality.
				errorInFile(
					luaUnprocessed, path, startPos+3, "Parser",
					"Preprocessor block variant does not contain a valid expression that results in a value."
				)

			else
				table.insert(metaParts, metaBlock)
				table.insert(metaParts, "\n")
			end

		-- Meta line. Example:
		-- !for i = 1, 3 do
		--    print("Marco? Polo!")
		-- !end
		--
		-- Extended meta line. Example:
		-- !newClass{
		--    name  = "Entity",
		--    props = {x=0, y=0},
		-- }
		--
		elseif tokType == "pp_entry" and not tok.double then
		-- elseif startOfLine and tokType == "pp_entry" and not tok.double then
			isMeta        = true
			metaStartLine = tok.line

			if tokensToProcess[1] then
				outputTokens(tokensToProcess)
				tokensToProcess = {}
			end

		elseif tokType == "pp_entry" then
			if tok.double then
				errorInFile(luaUnprocessed, path, tok.position, "Parser", "Unexpected double preprocessor token.")
			else
				errorInFile(luaUnprocessed, path, tok.position, "Parser", "Unexpected preprocessor token.")
			end

		-- Non-meta.
		--------------------------------

		--[[ Potential start of meta line. (Must be at the start of the line, possibly after whitespace.)  UPDATE: No longer true.
		elseif tokType == "whitespace" or (tokType == "comment" and not tok.long) then
			table.insert(tokensToProcess, tok)

			if not (tokType == "whitespace" and not tok.value:find("\n", 1, true)) then
				startOfLine = true
			end
		--]]

		else
			table.insert(tokensToProcess, tok)
			-- startOfLine = false
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

	local luaMeta = table.concat(metaParts)
	--[[ :PrintCode
	print("=META===============================")
	print(luaMeta)
	print("====================================")
	--]]

	currentMetaPath = path:gsub("%.%w+$", "")..".meta.lua"
	outputFromMeta  = {}

	local file = assert(io.open(currentMetaPath, "wb"))
	file:write(luaMeta)
	file:close()

	local chunk, err = loadstring(luaMeta, currentMetaPath)
	if not chunk then
		local ln, err = err:match'^%[string ".-"%]:(%d+): (.*)'
		errorOnLine(currentMetaPath, tonumber(ln), nil, "%s", err)
	end
	setfenv(chunk, remoteEnv)

	if messageHandler then  messageHandler("beforemeta", path)  end

	isRunningMeta  = true
	xpcall(chunk, function(err0)
		local path, ln, err = err0:match'^%[string "(.-)"%]:(%d+): (.*)'
		if err then
			errorOnLine(path, tonumber(ln), nil, "%s", err)
		else
			error(err0, 2)
		end
	end)
	isRunningMeta = false

	if not isDebug then
		os.remove(currentMetaPath)
	end

	local lua = table.concat(outputFromMeta)
	--[[ :PrintCode
	print("=OUTPUT=============================")
	print(lua)
	print("====================================")
	--]]

	currentMetaPath = ""
	outputFromMeta  = nil

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

	local pathOut = path:gsub("%.%w+$", "").."."..outputExtension
	local file    = assert(io.open(pathOut, "wb"))
	file:write(specialFirstLine or "")
	file:write(lua)
	file:close()

	-- Test if the output is valid Lua.
	local chunk, err = loadstring(lua, pathOut)
	if not chunk then
		local ln, err = err:match'^%[string ".-"%]:(%d+): (.*)'
		errorOnLine(pathOut, tonumber(ln), nil, "%s", err)
	end

	if messageHandler then  messageHandler("filedone", path, pathOut)  end

	if processingInfoPath ~= "" then

		-- :SavedInfo
		table.insert(processingInfo.files, {
			path                = path,
			hasPreprocessorCode = hasPreprocessorCode,
		})

	end

	printfNoise("Processing '%s' successful! (%.3fs)", path, os.clock()-startClockForPath)
	printfNoise(("-"):rep(#header))
end

if processingInfoPath ~= "" then
	printfNoise("Saving processing info to '%s'.", processingInfoPath)

	local luaParts = {"return"}
	assert(serialize(luaParts, processingInfo))
	local lua = table.concat(luaParts)

	local file = assert(io.open(processingInfoPath, "wb"))
	file:write(lua)
	file:close()
end

printfNoise(
	"All done! (%.3fs, %.0f lines, %.0f tokens, %s)",
	os.clock()-startClock, lineCount, tokenCount, formatBytes(byteCount)
)

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
