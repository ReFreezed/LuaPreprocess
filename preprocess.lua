--[[============================================================
--=
--=  LuaPreprocess library
--=  by Marcus 'ReFreezed' Thunström
--=
--=  License: MIT (see the bottom of this file)
--=  Website: https://github.com/ReFreezed/LuaPreprocess
--=
--=  Tested with Lua 5.1, 5.2 and 5.3.
--=
--==============================================================

	API:

	Global functions in metaprograms:
	- escapePattern
	- getFileContents, fileExists
	- printf
	- run
	- tokenize, newToken, concatTokens, removeUselessTokens, eachToken, isToken, getNextUsefulToken
	- toLua, serialize
	Only in metaprogram:
	- outputValue, outputLua

	Search this file for 'EnvironmentTable' for more info.

	Exported stuff from the library:
	- (all the functions above)
	- VERSION
	- metaEnvironment
	- processFile, processString

	Search this file for 'ExportTable' for more info.

----------------------------------------------------------------

	How to metaprogram:

	The exclamation mark (!) is used to indicate what code is part
	of the metaprogram. There are 4 ways to write metaprogram code:

	!...     The line will simply run during preprocessing. The line can span over multiple actual lines if it contains brackets.
	!!...    The line will appear in both the metaprogram and the final program. The line must be an assignment.
	!(...)   The result of the parenthesis will be outputted as a literal if it's an expression, otherwise it'll just run.
	!!(...)  The expression in the parenthesis will be outputted as Lua code. The expression must result in a string.

	Short examples:

	!if not isDeveloper then
		sendTelemetry()
	!end

	!!local tau = 2*math.pi -- The expression will be evaluated in the metaprogram and the result will appear in the final program as a literal.

	local bigNumber = !(5^10)

	local font = !!(isDeveloper and "loadDevFont()" or "loadUserFont()")

----------------------------------------------------------------

	-- Example program:

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

	-- Dual code (both preprocessor line and final output).
	!!local partial = "Hello"
	local   whole   = partial..!(partial..", world!")
	print(whole) -- HelloHello, world!

	-- Beware in preprocessor blocks that only call a single function!
	!(func())  -- This will bee seen as an inline block and output whatever value func() returns (nil if nothing) as a literal.
	!(func();) -- If that's not wanted then a trailing ";" will prevent that. This line won't output anything by itself.
	-- When the full metaprogram is generated, "!(func())" translates into "outputValue(func())"
	-- while "!(func();)" simply translates into "func();" (because "outputValue(func();)" would be invalid Lua code).
	-- Though in this specific case a preprocessor line would be nicer:
	!func()

--============================================================]]

local VERSION = "1.7.0"

local KEYWORDS = {
	"and","break","do","else","elseif","end","false","for","function","if","in",
	"local","nil","not","or","repeat","return","then","true","until","while",
	-- Lua 5.2
	"goto",
} for i, v in ipairs(KEYWORDS) do  KEYWORDS[v], KEYWORDS[i] = true, nil  end

local PUNCTUATION = {
	"+",  "-",  "*",  "/",  "%",  "^",  "#",
	"==", "~=", "<=", ">=", "<",  ">",  "=",
	"(",  ")",  "{",  "}",  "[",  "]",
	";",  ":",  ",",  ".",  "..", "...",
	-- Lua 5.2
	"::",
	-- Lua 5.3
	"//", "&",  "|",  "~",  ">>", "<<",
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

local USELESS_TOKENS = {whitespace=true, comment=true}

local ERROR_UNFINISHED_VALUE = 1

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

local _error                   = error

local metaEnv                  = nil

local isDebug                  = false
local onError                  = _error

local isRunningMeta            = false
local metaPathForErrorMessages = ""
local outputFromMeta           = nil

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
local F
local getFileContents, fileExists
local getLineNumber
local getNextUsableToken
local insertTokenRepresentations
local isAny
local isToken
local loadLuaString, loadLuaFile
local outputLineNumber, maybeOutputLineNumber
local pack, unpack
local parseStringlike
local printf, printTokens
local serialize, toLua
local tokenize

F = string.format

function printf(s, ...)
	print(s:format(...))
end
function printTokens(tokens, filter)
	for i, tok in ipairs(tokens) do
		if not (filter and USELESS_TOKENS[tok.type]) then
			printf("%d  %-12s '%s'", i, tok.type, (F("%q", tostring(tok.value)):sub(2, -2):gsub("\\\n", "\\n")))
		end
	end
end

function error(err, level)
	level = 1+(level or 1)
	print(debug.traceback("Error: "..tostring(err), level))
	onError(err, level)
end
function errorline(err)
	print("Error: "..tostring(err))
	onError(err, 2)
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
	onError(s, 2)
end
function errorInFile(contents, path, ptr, agent, s, ...)
	s = s:format(...)

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
			path, ln, agent, s, lastLine, ("-"):rep(col)
		)
	else
		printf(
			"Error @ %s:%d: %s\n>\n> %s\n> %s^\n>",
			path, ln,        s, lastLine, ("-"):rep(col-1)
		)
	end
	onError(s, 2)

	return s
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

local NUM_HEX_FRAC_EXP = ("^( 0x ([%dA-Fa-f]*) %.([%dA-Fa-f]+) [Pp]([-+]?[%dA-Fa-f]+) )"):gsub(" +", "")
local NUM_HEX_FRAC     = ("^( 0x ([%dA-Fa-f]*) %.([%dA-Fa-f]+)                        )"):gsub(" +", "")
local NUM_HEX_EXP      = ("^( 0x ([%dA-Fa-f]+)                 [Pp]([-+]?[%dA-Fa-f]+) )"):gsub(" +", "")
local NUM_HEX          = ("^( 0x  [%dA-Fa-f]+                                         )"):gsub(" +", "")
local NUM_DEC_FRAC_EXP = ("^(     %d*          %.%d+           [Ee][-+]?%d+           )"):gsub(" +", "")
local NUM_DEC_FRAC     = ("^(     %d*          %.%d+                                  )"):gsub(" +", "")
local NUM_DEC_EXP      = ("^(     %d+                          [Ee][-+]?%d+           )"):gsub(" +", "")
local NUM_DEC          = ("^(     %d+                                                 )"):gsub(" +", "")

-- tokens = tokenize( lua, filePath, allowBacktickStrings [, allowPreprocessorTokens=false ] )
function tokenize(s, path, allowBacktickStrings, allowMetaTokens)
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
			local           lua52Hex, i1, i2, numStr = true,  s:find(NUM_HEX_FRAC_EXP, ptr)
			if not i1 then  lua52Hex, i1, i2, numStr = true,  s:find(NUM_HEX_FRAC,     ptr)  end
			if not i1 then  lua52Hex, i1, i2, numStr = true,  s:find(NUM_HEX_EXP,      ptr)  end
			if not i1 then  lua52Hex, i1, i2, numStr = false, s:find(NUM_HEX,          ptr)  end
			if not i1 then  lua52Hex, i1, i2, numStr = false, s:find(NUM_DEC_FRAC_EXP, ptr)  end
			if not i1 then  lua52Hex, i1, i2, numStr = false, s:find(NUM_DEC_FRAC,     ptr)  end
			if not i1 then  lua52Hex, i1, i2, numStr = false, s:find(NUM_DEC_EXP,      ptr)  end
			if not i1 then  lua52Hex, i1, i2, numStr = false, s:find(NUM_DEC,          ptr)  end

			if not numStr then
				return nil, errorInFile(s, path, ptr, "Tokenizer", "Malformed number.")
			end
			if s:find("^[%w_]", i2+1) then
				-- This is actually only an error in Lua 5.1. Maybe we should issue a warning instead of an error here?
				return nil, errorInFile(s, path, i2+1, "Tokenizer", "Malformed number.")
			end

			local n = tonumber(numStr)

			-- Support hexadecimal floats in Lua 5.1.
			if not n and lua52Hex then
				local               _, intStr, fracStr, expStr = numStr:match(NUM_HEX_FRAC_EXP)
				if not intStr then  _, intStr, fracStr         = numStr:match(NUM_HEX_FRAC) ; expStr  = "0"  end
				if not intStr then  _, intStr,          expStr = numStr:match(NUM_HEX_EXP)  ; fracStr = ""   end
				assert(intStr, numStr)

				n = tonumber(intStr, 16) or 0 -- intStr may be "".

				local fracValue = 1
				for i = 1, #fracStr do
					fracValue = fracValue/16
					n         = n+tonumber(fracStr:sub(i, i), 16)*fracValue
				end

				n = n*2^expStr:gsub("^+", "")
			end

			if not n then
				return nil, errorInFile(s, path, ptr, "Tokenizer", "Invalid number.")
			end

			ptr = i2+1
			tok = {type="number", representation=numStr, value=n}

		-- Comment.
		elseif s:find("^%-%-", ptr) then
			local reprStart = ptr
			ptr = ptr+2

			tok, ptr = parseStringlike(s, ptr)
			if not tok then
				local errCode = ptr
				if errCode == ERROR_UNFINISHED_VALUE then
					return nil, errorInFile(s, path, reprStart, "Tokenizer", "Unfinished long comment.")
				else
					return nil, errorInFile(s, path, reprStart, "Tokenizer", "Invalid comment.")
				end
			end

			if tok.long then
				-- Check for nesting of [[...]], which is depricated in Lua.
				local chunk, err = loadLuaString("--"..tok.representation)
				if not chunk then
					local lnInString, _err = err:match"^%[string \".-\"%]:(%d+): (.*)"
					if not _err then
						return nil, errorInFile(s, path, reprStart, "Tokenizer", "Malformed long comment.")
					end

					return nil, errorOnLine(
						path, getLineNumber(s, reprStart)+tonumber(lnInString)-1,
						"Tokenizer", "Malformed long comment: %s", _err
					)
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
					return nil, errorInFile(s, path, reprStart, "Tokenizer", "Unfinished string.")

				elseif c == quoteChar then
					reprEnd  = ptr
					valueEnd = ptr-1
					ptr      = reprEnd+1
					break

				elseif c == "\\" then
					-- Note: We don't have to look for multiple characters after
					-- the escape, like \nnn - this algorithm works anyway.
					if ptr+1 > #s then
						return nil, errorInFile(s, path, reprStart, "Tokenizer", "Unfinished string after escape.")
					end
					ptr = ptr+2

				else
					ptr = ptr+1
				end
			end

			local repr = s:sub(reprStart, reprEnd)

			local valueChunk = loadLuaString("return"..repr)
			if not valueChunk then
				return nil, errorInFile(s, path, reprStart, "Tokenizer", "Malformed string.")
			end

			local v = valueChunk()
			assert(type(v) == "string")

			tok = {type="string", representation=repr, value=valueChunk(), long=false}

		-- Long string.
		elseif s:find("^%[=*%[", ptr) then
			local reprStart = ptr

			tok, ptr = parseStringlike(s, ptr)
			if not tok then
				local errCode = ptr
				if errCode == ERROR_UNFINISHED_VALUE then
					return nil, errorInFile(s, path, reprStart, "Tokenizer", "Unfinished long string.")
				else
					return nil, errorInFile(s, path, reprStart, "Tokenizer", "Invalid long string.")
				end
			end

			-- Check for nesting of [[...]], which is depricated in Lua.
			local valueChunk, err = loadLuaString("return"..tok.representation)
			if not valueChunk then
				local lnInString, _err = err:match"^%[string \".-\"%]:(%d+): (.*)"
				if not _err then
					return nil, errorInFile(s, path, reprStart, "Tokenizer", "Malformed long string.")
				end

				return nil, errorOnLine(
					path, getLineNumber(s, reprStart)+tonumber(lnInString)-1,
					"Tokenizer", "Malformed long string: %s", _err
				)
			end

			local v = valueChunk()
			assert(type(v) == "string")

			tok.type  = "string"
			tok.value = v

		-- Backtick string.
		elseif allowBacktickStrings and s:find("^`", ptr) then
			local i1, i2, v = s:find("^`([^`]*)`", ptr)
			if not i2 then
				return nil, errorInFile(s, path, ptr, "Tokenizer", "Unfinished backtick string.")
			end

			local repr = F("%q", v)

			ptr = i2+1
			tok = {type="string", representation=repr, value=v, long=false}

		-- Whitespace.
		elseif s:find("^%s", ptr) then
			local i1, i2, whitespace = s:find("^(%s+)", ptr)

			ptr = i2+1
			tok = {type="whitespace", representation=whitespace, value=whitespace}

		-- Punctuation etc.
		-- "//", ">>", "<<",
		elseif s:find("^%.%.%.", ptr) then
			local repr = s:sub(ptr, ptr+2)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr
		elseif s:find("^%.%.", ptr) or s:find("^[=~<>]=", ptr) or s:find("^::", ptr) or s:find("^//", ptr) or s:find("^<<", ptr) or s:find("^>>", ptr) then
			local repr = s:sub(ptr, ptr+1)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr
		elseif s:find("^[+%-*/%%^#<>=(){}[%];:,.]", ptr) then
			local repr = s:sub(ptr, ptr)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr

		-- Preprocessor: Entry.
		elseif allowMetaTokens and s:find("^!", ptr) then
			local double = s:find("^!", ptr+1) ~= nil
			local repr   = s:sub(ptr, ptr+(double and 1 or 0))
			tok = {type="pp_entry", representation=repr, value=repr, double=double}
			ptr = ptr+#repr

		else
			return nil, errorInFile(s, path, ptr, "Tokenizer", "Unknown character.")
		end

		tok.line     = ln
		tok.position = tokenPos

		ln = ln+countString(tok.representation, "\n", true)
		tok.lineEnd = ln

		table.insert(tokens, tok)
		-- print(#tokens, tok.type, tok.representation)
	end

	return tokens
end

function concatTokens(tokens, lastLn, addLineNumbers)
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

function insertTokenRepresentations(parts, tokens, i1, i2)
	for i = i1, i2 do
		table.insert(parts, tokens[i].representation)
	end
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

-- assertarg( argumentNumber, value, expectedValueType1, ... )
function assertarg(n, v, ...)
	local vType = type(v)

	for i = 1, select("#", ...) do
		if vType == select(i, ...) then  return  end
	end

	local fName   = debug.getinfo(2, "n").name
	local expects = table.concat({...}, " or ")

	if fName == "" then  fName = "?"  end

	error(F("bad argument #%d to '%s' (%s expected, got %s)", n, fName, expects, vType), 3)
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

-- luaString, error = toLua( value )
function toLua(v)
	local buffer = {}

	local ok, err = serialize(buffer, v)
	if not ok then  return nil, err  end

	return table.concat(buffer)
end

function escapePattern(s)
	return (s:gsub("[-+*^?$.%%()[%]]", "%%%0"))
end

function outputLineNumber(parts, ln)
	table.insert(parts, "--[[@")
	table.insert(parts, ln)
	table.insert(parts, "]]")
end
function maybeOutputLineNumber(parts, tok, lastLn)
	if tok.line == lastLn or USELESS_TOKENS[tok.type] then  return lastLn  end

	outputLineNumber(parts, tok.line)
	return tok.line
end
--[=[
function maybeOutputLineNumber(parts, tok, lastLn, fromMetaToOutput)
	if tok.line == lastLn or USELESS_TOKENS[tok.type] then  return lastLn  end

	if fromMetaToOutput then
		table.insert(parts, '__LUA"--[[@'..tok.line..']]"\n')
	else
		table.insert(parts, "--[[@"..tok.line.."]]")
	end
	return tok.line
end
]=]

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
if IS_LUA_52_OR_LATER then
	pack = table.pack
else
	function pack(...)
		return {n=select("#", ...), ...}
	end
end

unpack = IS_LUA_52_OR_LATER and table.unpack or _G.unpack

if IS_LUA_52_OR_LATER then
	function loadLuaString(lua, chunkName, env)
		return load(lua, chunkName, "bt", env)
	end
else
	function loadLuaString(lua, chunkName, env)
		local chunk, err = loadstring(lua, chunkName)
		if not chunk then  return chunk, err  end

		if env then  setfenv(chunk, env)  end

		return chunk
	end
end

if IS_LUA_52_OR_LATER then
	function loadLuaFile(path, env)
		return loadfile(path, "bt", env)
	end
else
	function loadLuaFile(path, env)
		local chunk, err = loadfile(path)
		if not chunk then  return chunk, err  end

		if env then  setfenv(chunk, env)  end

		return chunk
	end
end

-- token, index = getNextUsableToken( tokens, startIndex [, indexLimit, direction=1 ] )
function getNextUsableToken(tokens, i, iLimit, dir)
	dir = dir or 1

	iLimit
		=   dir < 0
		and math.max((iLimit or 1), 1)
		or  math.min((iLimit or math.huge), #tokens)

	for i = i, iLimit, dir do
		if not USELESS_TOKENS[tokens[i].type] then
			return tokens[i], i
		end
	end

	return nil
end

-- bool = isToken( token, tokenType [, tokenValue=any ] )
function isToken(tok, tokType, v)
	return tok.type == tokType and (v == nil or tok.value == v)
end

function getLineNumber(s, ptr)
	local _, nlCount = s:sub(1, ptr):gsub("\n", "\n")
	return 1+nlCount
end

--==============================================================
--= Preprocessor Functions =====================================
--==============================================================



-- :EnvironmentTable
metaEnv = copyTable(_G, true) -- Include all standard Lua stuff.
metaEnv._G = metaEnv

local metaFuncs = {}

-- printf()
--   Print a formatted string.
--   printf( format, value1, ... )
metaFuncs.printf = printf

-- getFileContents()
--   Get the entire contents of a binary file or text file. Return nil and a message on error.
--   contents, error = getFileContents( path [, isTextFile=false ] )
metaFuncs.getFileContents = getFileContents

-- fileExists()
--   Check if a file exists.
--   bool = fileExists( path )
metaFuncs.fileExists = fileExists

-- toLua()
--   Convert a value to a Lua literal. Does not work with certain types, like functions or userdata.
--   Returns nil and a message if an error ocurred.
--   luaString, error = toLua( value )
metaFuncs.toLua = toLua

-- serialize()
--   Same as toLua() except adds the result to an array instead of returning the Lua code as a string.
--   success, error = serialize( buffer, value )
metaFuncs.serialize = serialize

-- escapePattern()
--   Escape a string so it can be used in a pattern as plain text.
--   escapedString = escapePattern( string )
metaFuncs.escapePattern = escapePattern

-- isToken()
--   Check if a token is of a specific type, optionally also check it's value.
--   bool = isToken( token, tokenType [, tokenValue=any ] )
metaFuncs.isToken = isToken

-- run()
--   Execute a Lua file. Similar to dofile().
--   returnValue1, ... = run( path )
function metaFuncs.run(path)
	assertarg(1, path, "string")

	local chunk, err = loadLuaFile(path, metaEnv)
	if not chunk then  errorline(err)  end

	-- We want multiple return values while avoiding a tail call to preserve stack info.
	local returnValues = pack(chunk())
	return unpack(returnValues, 1, returnValues.n)
end

-- outputValue()
--   Output one or more values, like strings or tables, as literals.
--   outputValue( value1, ... )
function metaFuncs.outputValue(...)
	errorIfNotRunningMeta(2)

	local argCount = select("#", ...)
	if argCount == 0 then
		error("No values to output.", 2)
		-- local ln = debug.getinfo(2, "l").currentline
		-- errorOnLine(metaPathForErrorMessages, ln, "MetaProgram", "No values to output.")
	end

	for i = 1, argCount do
		local v = select(i, ...)
		local ok, err = serialize(outputFromMeta, v)

		if not ok then
			local ln = debug.getinfo(2, "l").currentline
			errorOnLine(metaPathForErrorMessages, ln, "MetaProgram", "%s", err)
		end
	end
end

-- outputLua()
--   Output one or more strings as raw Lua code.
--   outputLua( luaString1, ... )
function metaFuncs.outputLua(...)
	errorIfNotRunningMeta(2)

	local argCount = select("#", ...)
	if argCount == 0 then
		error("No Lua code to output.", 2)
		-- local ln = debug.getinfo(2, "l").currentline
		-- errorOnLine(metaPathForErrorMessages, ln, "MetaProgram", "No Lua code to output.")
	end

	for i = 1, argCount do
		local lua = select(i, ...)
		assertarg(i, lua, "string")
		table.insert(outputFromMeta, lua)
	end
end

-- tokenize()
--   Convert Lua code to tokens. Returns nil and a message on error. (See newToken() for token types.)
--   tokens, error = tokenize( luaString [, allowPreprocessorTokens=false ] )
--   token = { type=tokenType, representation=representation, value=value, line=lineNumber, lineEnd=lineNumber, position=bytePosition, ... }
function metaFuncs.tokenize(lua, allowMetaTokens)
	local tokens, err = tokenize(lua, "<string>", false, allowMetaTokens)
	return tokens, err
end

-- removeUselessTokens()
--   Remove whitespace and comment tokens.
--   removeUselessTokens( tokens )
function metaFuncs.removeUselessTokens(tokens)
	local len    = #tokens
	local offset = 0

	for i, tok in ipairs(tokens) do
		if USELESS_TOKENS[tok.type] then
			offset = offset-1
		else
			tokens[i+offset] = tok
		end
	end

	for i = len+offset+1, len do
		tokens[i] = nil
	end
end

-- eachToken()
--   Loop though tokens.
--   for index, token in eachToken( tokens [, ignoreUselessTokens=false ] ) do
local function nextUsefulToken(tokens, i)
	while true do
		i = i+1
		local tok = tokens[i]
		if not tok                      then  return         end
		if not USELESS_TOKENS[tok.type] then  return i, tok  end
	end
end
function metaFuncs.eachToken(tokens, ignoreUselessTokens)
	if ignoreUselessTokens then
		return nextUsefulToken, tokens, 0
	else
		return ipairs(tokens)
	end
end

-- getNextUsefulToken()
--   Get the next token that isn't a whitespace or comment. Returns nil if no more tokens are found.
--   token, index = getNextUsefulToken( tokens, startIndex [, steps=1 ] )
--   Specify a negative steps value to get an earlier token.
function metaFuncs.getNextUsefulToken(tokens, i1, steps)
	steps = (steps or 1)

	local i2, dir
	if steps == 0 then
		return tokens[i1], i1
	elseif steps < 0 then
		i2, dir = 1, -1
	else
		i2, dir = #tokens, 1
	end

	for i = i1, i2, dir do
		local tok = tokens[i]
		if not USELESS_TOKENS[tok.type] then
			steps = steps-dir
			if steps == 0 then  return tok, i  end
		end
	end

	return nil
end

-- newToken()
--   Create a new token. Different token types take different arguments.
--   token = newToken( tokenType, ... )
--
--   commentToken      = newToken( "comment",     contents [, forceLongForm=false ] )
--   identifierToken   = newToken( "identifier",  identifier )
--   keywordToken      = newToken( "keyword",     keyword )
--   numberToken       = newToken( "number",      number [, numberFormat="auto" ] )
--   punctuationToken  = newToken( "punctuation", symbol )
--   stringToken       = newToken( "string",      contents [, longForm=false ] )
--   whitespaceToken   = newToken( "whitespace",  contents )
--   preprocessorToken = newToken( "pp_entry",    isDouble )
--
--   commentToken      = { type="comment",     representation=string, value=string, long=isLongForm }
--   identifierToken   = { type="identifier",  representation=string, value=string }
--   keywordToken      = { type="keyword",     representation=string, value=string }
--   numberToken       = { type="number",      representation=string, value=number }
--   punctuationToken  = { type="punctuation", representation=string, value=string }
--   stringToken       = { type="string",      representation=string, value=string, long=isLongForm }
--   whitespaceToken   = { type="whitespace",  representation=string, value=string }
--   preprocessorToken = { type="pp_entry",    representation=string, value=string, double=isDouble }
--
-- Number formats:
--   "integer"      E.g. 42
--   "float"        E.g. 3.14
--   "scientific"   E.g. 0.7e+12
--   "SCIENTIFIC"   E.g. 0.7E+12 (upper case)
--   "hexadecimal"  E.g. 0x19af
--   "HEXADECIMAL"  E.g. 0x19AF (upper case)
--   "auto"         Note: Infinite numbers and NaN always get automatic format.
--
function metaFuncs.newToken(tokType, ...)
	if tokType == "comment" then
		local comment, long = ...
		long = not not (long or comment:find"[\r\n]")

		local repr
		if long then
			local equalSigns = ""

			while comment:find(F("]%s]", equalSigns), 1, true) do
				equalSigns = equalSigns.."="
			end

			repr = F("--[%s[%s]%s]", equalSigns, comment, equalSigns)

		else
			repr = F("--%s\n", comment)
		end

		return {type="comment", representation=repr, value=comment, long=long}

	elseif tokType == "identifier" then
		local ident = ...

		if ident == "" then
			error("Identifier length is 0.")
		elseif not ident:find"^[%a_][%w_]*$" then
			error(F("Bad identifier format: '%s'", ident))
		end

		return {type="identifier", representation=ident, value=ident}

	elseif tokType == "keyword" then
		local keyword = ...

		if not KEYWORDS[keyword] then
			error(F("Bad keyword '%s'.", keyword))
		end

		return {type="keyword", representation=keyword, value=keyword}

	elseif tokType == "number" then
		local n, numberFormat = ...
		numberFormat = numberFormat or "auto"

		-- Some of these are technically multiple other tokens. We could trigger an error but ehhh...
		-- @Incomplete: Hexadecimal floats.
		local numStr
			=  n            ~= n             and "0/0"
			or n            == math.huge     and "math.huge"
			or n            == -math.huge    and " -math.huge" -- The space prevents an accidental comment if a "-" is right before.
			or numberFormat == "auto"        and tostring(n)
			or numberFormat == "integer"     and F("%d", n)
			or numberFormat == "float"       and F("%f", n):gsub("(%d)0+$", "%1")
			or numberFormat == "scientific"  and F("%e", n):gsub("(%d)0+e", "%1e"):gsub("0+(%d+)$", "%1")
			or numberFormat == "SCIENTIFIC"  and F("%E", n):gsub("(%d)0+E", "%1E"):gsub("0+(%d+)$", "%1")
			or numberFormat == "hexadecimal" and (n == math.floor(n) and F("0x%x", n) or error("Hexadecimal floats not supported yet."))
			or numberFormat == "HEXADECIMAL" and (n == math.floor(n) and F("0x%X", n) or error("Hexadecimal floats not supported yet."))
			or error(F("Invalid number format '%s'.", numberFormat))

		return {type="number", representation=numStr, value=n}

	elseif tokType == "punctuation" then
		local symbol = ...

		-- Note: "!" and "!!" are of a different token type (pp_entry).
		if not PUNCTUATION[symbol] then
			error(F("Bad symbol '%s'.", symbol))
		end

		return {type="punctuation", representation=symbol, value=symbol}

	elseif tokType == "string" then
		local s, long = ...
		long = not not long

		local repr
		if long then
			local equalSigns = ""

			while s:find(F("]%s]", equalSigns), 1, true) do
				equalSigns = equalSigns.."="
			end

			repr = F("[%s[%s]%s]", equalSigns, s, equalSigns)

		else
			repr = F("%q", s):gsub("\\\n", "\\n")
		end

		return {type="string", representation=repr, value=s, long=long}

	elseif tokType == "whitespace" then
		local whitespace = ...

		if whitespace == "" then
			error("String is empty.")
		elseif whitespace:find"%S" then
			error("String contains non-whitespace characters.")
		end

		return {type="whitespace", representation=whitespace, value=whitespace}

	elseif tokType == "pp_entry" then
		local double = not not ...
		local symbol = double and "!!" or "!"
		return {type="pp_entry", representation=symbol, value=symbol, double=double}

	else
		error(F("Invalid token type '%s'.", tokType))
	end
end

-- concatTokens()
--   Concatinate tokens by their representations.
--   luaString = concatTokens( tokens )
function metaFuncs.concatTokens(tokens)
	return concatTokens(tokens)
end



for k, v in pairs(metaFuncs) do  metaEnv[k] = v  end

metaEnv.__VAL = metaEnv.outputValue
metaEnv.__LUA = metaEnv.outputLua



local function getLineCountWithCode(tokens)
	local lineCount = 0
	local lastLine  = 0

	for _, tok in ipairs(tokens) do
		if not USELESS_TOKENS[tok.type] and tok.lineEnd > lastLine then
			lineCount = lineCount+(tok.lineEnd-tok.line+1)
			lastLine  = tok.lineEnd
		end
	end

	return lineCount
end

local function _processFileOrString(params, isFile)
	if isFile then
		if not params.pathIn  then  error("Missing 'pathIn' in params.",  2)  end
		if not params.pathOut then  error("Missing 'pathOut' in params.", 2)  end
	else
		if not params.code    then  error("Missing 'code' in params.",    2)  end
	end

	local luaUnprocessed, pathIn

	if isFile then
		local err

		pathIn              = params.pathIn
		luaUnprocessed, err = getFileContents(pathIn)

		if not luaUnprocessed then
			errorline("Could not read file: "..err)
		end

	else
		pathIn         = "<code>"
		luaUnprocessed = params.code
	end

	local specialFirstLine, rest = luaUnprocessed:match"^(#[^\r\n]*\r?\n?)(.*)$"
	if specialFirstLine then
		luaUnprocessed = rest
	end

	local tokens    = tokenize(luaUnprocessed, pathIn, params.backtickStrings, true)
	local lastToken = tokens[#tokens]
	-- printTokens(tokens)

	-- Info variables.
	local processedByteCount  = #luaUnprocessed
	local lineCount           = (specialFirstLine and 1 or 0) + (lastToken and lastToken.line + countString(lastToken.representation, "\n") or 0)
	local lineCountCode       = getLineCountWithCode(tokens)
	local tokenCount          = #tokens
	local hasPreprocessorCode = false

	-- Generate metaprogram.
	--==============================================================

	for _, tok in ipairs(tokens) do
		if isToken(tok, "pp_entry") then
			hasPreprocessorCode = true
			break
		end
	end

	local tokensToProcess = {}
	local metaParts       = {}

	local tokenIndex      = 1
	local ln              = 0

	local function flushTokensToProcess()
		if not tokensToProcess[1] then  return  end

		local lua = concatTokens(tokensToProcess, ln, params.addLineNumbers)
		local luaMeta

		if isDebug then
			luaMeta = F("__LUA(%q)\n", lua):gsub("\\\n", "\\n")
		else
			luaMeta = F("__LUA%q", lua)
		end

		table.insert(metaParts, luaMeta)
		ln = tokensToProcess[#tokensToProcess].line

		tokensToProcess = {}
	end

	local function outputFinalDualValueStatement(metaLineIndexStart, metaLineIndexEnd)
		-- We expect the statement to look like any of these:
		-- !!local x = ...
		-- !!x = ...

		-- Check whether local or not.
		local tok, i = getNextUsableToken(tokens, metaLineIndexStart, metaLineIndexEnd)
		if not tok then
			errorInFile(
				luaUnprocessed, pathIn, tokens[metaLineIndexStart].position, "Parser",
				"Unexpected end of preprocessor line."
			)
		end

		local isLocal = isToken(tok, "keyword", "local")

		if isLocal then
			tok, i = getNextUsableToken(tokens, i+1, metaLineIndexEnd)
			if not tok then
				errorInFile(
					luaUnprocessed, pathIn, tokens[metaLineIndexStart].position, "Parser",
					"Unexpected end of preprocessor line."
				)
			end
		end

		-- Check for identifier.
		-- @Incomplete: Support multiple assignments. :MultipleAssignments
		if not isToken(tok, "identifier") then
			errorInFile(
				luaUnprocessed, pathIn, tok.position, "Parser",
				"Expected an identifier."
			)
		end

		local ident = tok.value

		-- Check for "=".
		tok, i = getNextUsableToken(tokens, i+1, metaLineIndexEnd)
		if not tok then
			errorInFile(
				luaUnprocessed, pathIn, tokens[metaLineIndexStart].position, "Parser",
				"Unexpected end of preprocessor line."
			)
		elseif isToken(tok, "punctuation", ",") then
			-- :MultipleAssignments
			errorInFile(
				luaUnprocessed, pathIn, tok.position, "Parser",
				"Preprocessor line must be a single assignment. (Multiple assignments are not supported.)"
			)
		elseif not isToken(tok, "punctuation", "=") then
			errorInFile(
				luaUnprocessed, pathIn, tok.position, "Parser",
				"Preprocessor line must be an assignment."
			)
		end

		local indexAfterEqualSign = i+1

		if not getNextUsableToken(tokens, indexAfterEqualSign, metaLineIndexEnd) then
			errorInFile(
				luaUnprocessed, pathIn, tok.position, "Parser",
				"Unexpected end of preprocessor line."
			)
		end

		-- Check if the rest of the line is an expression.
		if true then
			local lastUsableToken, lastUsableIndex = getNextUsableToken(tokens, metaLineIndexEnd+1, 1, -1)
			local parts = {}

			table.insert(parts, "return (")
			if isToken(lastUsableToken, "punctuation", ";") then
				insertTokenRepresentations(parts, tokens, indexAfterEqualSign, lastUsableIndex-1)
			else
				insertTokenRepresentations(parts, tokens, indexAfterEqualSign, metaLineIndexEnd)
			end
			table.insert(parts, "\n)")

			if not loadstring(table.concat(parts)) then
				errorInFile(
					luaUnprocessed, pathIn, tokens[metaLineIndexStart].position, "Parser",
					"Dual code line must be a single assignment statement."
				)
			end
		end

		-- Output.
		if isDebug then
			table.insert(metaParts, '__LUA("')

			if params.addLineNumbers then
				outputLineNumber(metaParts, tokens[metaLineIndexStart].line)
			end

			if isLocal then  table.insert(metaParts, 'local ')  end

			table.insert(metaParts, ident)
			table.insert(metaParts, ' = "); __VAL(')
			table.insert(metaParts, ident)
			table.insert(metaParts, '); __LUA("\\n")\n')

		else
			table.insert(metaParts, '__LUA"')

			if params.addLineNumbers then
				outputLineNumber(metaParts, tokens[metaLineIndexStart].line)
			end

			if isLocal then  table.insert(metaParts, 'local ')  end

			table.insert(metaParts, ident)
			table.insert(metaParts, ' = "__VAL(')
			table.insert(metaParts, ident)
			table.insert(metaParts, ')__LUA"\\n"\n')
		end

		flushTokensToProcess()
	end

	-- Note: Can be multiple lines if extended.
	local function processMetaLine(isDual, metaStartLine)
		local metaLineIndexStart = tokenIndex
		local bracketBalance     = 0

		while true do
			local tok = tokens[tokenIndex]
			if not tok then  break  end

			local tokType = tok.type

			if
				bracketBalance == 0 and (
					(tokType == "whitespace" and tok.value:find("\n", 1, true)) or
					(tokType == "comment"    and not tok.long)
				)
			then
				if tokType == "comment" then
					table.insert(metaParts, tok.representation)
				else
					table.insert(metaParts, "\n")
				end

				if isDual then
					outputFinalDualValueStatement(metaLineIndexStart, tokenIndex-1)
				end

				break

			elseif tokType == "pp_entry" then
				errorInFile(
					luaUnprocessed, pathIn, tok.position, "Parser",
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
							luaUnprocessed, pathIn, tok.position, "Parser",
							"Unexpected '%s'. Preprocessor line"
								..(tok.line == metaStartLine and "" or " (starting at line %d)")
								.." has unbalanced brackets.",
							tok.value, metaStartLine
						)
					end
				end
			end

			tokenIndex = tokenIndex+1
		end
	end

	while true do
		local tok = tokens[tokenIndex]
		if not tok then  break  end

		local tokType = tok.type

		-- Meta block or start of meta line.
		--------------------------------

		-- Meta block. Examples:
		-- !( function sum(a, b) return a+b; end )
		-- local text = !("Hello, mr. "..getName())
		-- _G.!!("myRandomGlobal"..math.random(5)) = 99
		if tokType == "pp_entry" and tokens[tokenIndex+1] and isToken(tokens[tokenIndex+1], "punctuation", "(") then
			local startToken  = tok
			local startPos    = tok.position
			local startLine   = tok.line
			local doOutputLua = tok.double
			tokenIndex = tokenIndex+2 -- Jump past "!(" or "!!(".

			flushTokensToProcess()

			local tokensInBlock = {}
			local depth         = 1

			while true do
				tok = tokens[tokenIndex]
				if not tok then
					errorInFile(luaUnprocessed, pathIn, startPos, "Parser", "Missing end of preprocessor block.")
				end

				tokType = tok.type

				if tokType == "punctuation" and tok.value == "(" then
					depth = depth+1

				elseif tokType == "punctuation" and tok.value == ")" then
					depth = depth-1
					if depth == 0 then  break  end

				elseif tokType == "pp_entry" then
					errorInFile(
						luaUnprocessed, pathIn, tok.position, "Parser",
						"Preprocessor token inside metaprogram"..(tok.line == startLine and "." or " (starting at line %d)."),
						startLine
					)
				end

				table.insert(tokensInBlock, tok)
				tokenIndex = tokenIndex+1
			end

			local metaBlock = concatTokens(tokensInBlock, nil, params.addLineNumbers)

			if loadLuaString("return("..metaBlock..")") then
				table.insert(metaParts, (doOutputLua and "__LUA((" or "__VAL(("))
				table.insert(metaParts, metaBlock)
				table.insert(metaParts, "))\n")

			elseif doOutputLua then
				-- We could do something other than error here. Room for more functionality.
				errorInFile(
					luaUnprocessed, pathIn, startPos+3, "Parser",
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
		-- Dual code. Example:
		-- !!local foo = "A"
		-- local bar = foo..!(foo)
		--
		elseif tokType == "pp_entry" then
			flushTokensToProcess()

			tokenIndex = tokenIndex+1
			processMetaLine(tok.double, tok.line)

		-- Non-meta.
		--------------------------------
		else
			table.insert(tokensToProcess, tok)
		end
		--------------------------------

		tokenIndex = tokenIndex+1
	end

	flushTokensToProcess()

	-- Run metaprogram.
	--==============================================================

	local luaMeta = table.concat(metaParts)
	--[[ :PrintCode
	print("=META===============================")
	print(luaMeta)
	print("====================================")
	--]]

	metaPathForErrorMessages = params.pathMeta or "<meta>"
	outputFromMeta           = {}

	if params.pathMeta then
		local file = assert(io.open(params.pathMeta, "wb"))
		file:write(luaMeta)
		file:close()
	end

	local chunk, err = loadLuaString(luaMeta, metaPathForErrorMessages, metaEnv)
	if not chunk then
		local ln, err = err:match'^%[string ".-"%]:(%d+): (.*)'
		errorOnLine(metaPathForErrorMessages, tonumber(ln), nil, "%s", err)
		return nil, err
	end

	if params.onBeforeMeta then  params.onBeforeMeta()  end

	isRunningMeta = true
	local ok, err = xpcall(chunk, function(err0)
		local path, ln, err = tostring(err0):match'^%[string "(.-)"%]:(%d+): (.*)'
		if err then
			errorOnLine(path, tonumber(ln), nil, "%s", err)
		else
			error(err0, 2)
		end
	end)
	isRunningMeta = false

	if not ok then
		-- Note: The caller should clean up metaPathForErrorMessages etc. on error.
		return nil, err
	end

	if not isDebug and params.pathMeta then
		os.remove(params.pathMeta)
	end

	local lua = table.concat(outputFromMeta)
	--[[ :PrintCode
	print("=OUTPUT=============================")
	print(lua)
	print("====================================")
	--]]

	metaPathForErrorMessages = ""
	outputFromMeta           = nil

	if params.onAfterMeta then
		local luaModified = params.onAfterMeta(lua)

		if type(luaModified) == "string" then
			lua = luaModified
		elseif luaModified ~= nil then
			errorline("onAfterMeta() did not return a string. (Got "..type(luaModified)..")")
		end
	end

	-- Write output file.
	----------------------------------------------------------------

	local pathOut = isFile and params.pathOut or "<output>"

	if isFile then
		local file = assert(io.open(pathOut, "wb"))
		file:write(specialFirstLine or "")
		file:write(lua)
		file:close()
	end

	-- Test if the output is valid Lua.
	local chunk, err = loadLuaString(lua, pathOut)
	if not chunk then
		local ln, err = err:match'^%[string ".-"%]:(%d+): (.*)'
		errorOnLine(pathOut, tonumber(ln), nil, "%s", err)
		return nil, err
	end

	-- :ProcessInfo
	local info = {
		processedByteCount  = processedByteCount,
		lineCount           = lineCount,
		linesOfCode         = lineCountCode,
		tokenCount          = tokenCount,
		hasPreprocessorCode = hasPreprocessorCode,
	}

	if isFile then
		return info
	else
		if specialFirstLine then
			lua = specialFirstLine..lua
		end
		return lua, info
	end
end

local function processFileOrString(params, isFile)
	local returnValues = nil
	local err          = nil

	isDebug = params.debug
	onError = function(_err)
		err = _err
		if params.onError then  params.onError(err)  end
	end

	xpcall(
		function()
			returnValues = pack(_processFileOrString(params, isFile))
		end,
		onError
	)

	isDebug = false
	onError = _error

	-- Cleanup in case an error happened.
	isRunningMeta            = false
	metaPathForErrorMessages = ""
	outputFromMeta           = nil

	if err then
		return nil, err
	else
		return unpack(returnValues, 1, returnValues.n)
	end
end

local function processFile(params)
	return processFileOrString(params, true)
end

local function processString(params)
	return processFileOrString(params, false)
end



-- :ExportTable
local lib = {

	-- Processing functions.
	----------------------------------------------------------------

	-- processFile()
	-- Process a Lua file.
	--
	-- info, error = processFile( params )
	-- info: Table with various information, or nil if an error happened. See 'ProcessInfo' for more info.
	-- error: Error message, or nil if no error happened.
	--
	-- params: Table with these fields:
	--   pathIn          = pathToInputFile       -- [Required]
	--   pathMeta        = pathForMetaprogram    -- [Optional] You can inspect this temporary output file if an error ocurrs in the metaprogram.
	--   pathOut         = pathToOutputFile      -- [Required]
	--
	--   addLineNumbers  = boolean               -- [Optional] Add comments with line numbers to the output.
	--   debug           = boolean               -- [Optional] Debug mode. The metaprogram file is formatted more nicely and does not get deleted automatically.
	--
	--   backtickStrings = boolean               -- [Optional] Enable the backtick (`) to be used as string literal delimiters. Backtick strings don't interpret any escape sequences and can't contain backticks.
	--
	--   onAfterMeta     = function( luaString ) -- [Optional] Here you can modify and return the Lua code before it's written to 'pathOut'.
	--   onBeforeMeta    = function( )           -- [Optional] Called before the metaprogram runs.
	--   onError         = function( error )     -- [Optional] You can use this to get traceback information. 'error' is the same value as what is returned from processFile().
	--
	processFile = processFile,

	-- processString()
	-- Process Lua code.
	--
	-- luaString, info = processString( params )
	-- info: Table with various information, or a message if an error happened. See 'ProcessInfo' for more info.
	--
	-- params: Table with these fields:
	--   code            = luaString             -- [Required]
	--   pathMeta        = pathForMetaprogram    -- [Optional] You can inspect this temporary output file if an error ocurrs in the metaprogram.
	--
	--   addLineNumbers  = boolean               -- [Optional] Add comments with line numbers to the output.
	--   debug           = boolean               -- [Optional] Debug mode. The metaprogram file is formatted more nicely and does not get deleted automatically.
	--
	--   backtickStrings = boolean               -- [Optional] Enable the backtick (`) to be used as string literal delimiters. Backtick strings don't interpret any escape sequences and can't contain backticks.
	--
	--   onBeforeMeta    = function( )           -- [Optional] Called before the metaprogram runs.
	--   onError         = function( error )     -- [Optional] You can use this to get traceback information. 'error' is the same value as the second returned value from processString().
	--
	processString = processString,

	-- Values.
	----------------------------------------------------------------

	VERSION         = VERSION, -- The version of LuaPreprocess.
	metaEnvironment = metaEnv, -- The environment used for metaprograms.
}

-- Include all functions from the metaprogram environment.
for k, v in pairs(metaFuncs) do  lib[k] = v  end

return lib

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
