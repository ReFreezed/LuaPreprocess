--[[!===========================================================
--=
--=  Lua preprocessor
--=  by Marcus 'ReFreezed' Thunström (marcus.refreezed.com)
--=
--=  Tested for Lua 5.1.
--=
--=  Script usage:
--=    lua main.lua path1 [path2...]
--=
--==============================================================

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
	!{
	local dogWord = "Woof "
	function getDogText()
		return dogWord:rep(3)
	end
	}

	-- Preprocessor inline block. (Expression that returns a value.)
	local text = !{"The dog said: "..getDogText()}

----------------------------------------------------------------

	Additional global functions in metaprogram:
	- outputValue, outputLua
	- printf
	- run

	Search this file for 'metaEnv' for more info.

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

--==============================================================
--= Local Functions ============================================
--==============================================================
local concatTokens
local error, errorline, errorOnLine, errorInFile
local parseStringlike
local printf, printTokens
local tokensizeLua

function printf(s, ...)
	print(s:format(...))
end
function printTokens(tokens, filter)
	for i, tok in ipairs(tokens) do
		if not (filter and (tok.type == "whitespace" or tok.type == "comment")) then
			printf("%d  %-12s '%s'", i, tok.type, (("%q"):format(tostring(tok.value)):sub(2, -2):gsub("\\\n", "\\n")))
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
	tok = {type="stringlike", representation=repr, value=v, long=isLong}

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

--==============================================================
--= Preprocessor Script ========================================
--==============================================================

local header = "= LuaPreprocess v"..VERSION..os.date", %Y-%m-%d %H:%M:%S ="
print(("="):rep(#header))
print(header)
print(("="):rep(#header))

local paths = {...}

if not paths[1] then
	errorline("Missing path argument(s).")
end

for _, path in ipairs(paths) do
	if not path:find"%.lua2p$" then
		errorline("Invalid path '"..path.."'. (Paths are currently required to end with .lua2p)")
	end
end

math.randomseed(os.time()) -- Just in case math.random() is used anywhere.

for _, path in ipairs(paths) do
	printf("Processing '%s'...", path)

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
		local luaMeta = ("outputLua(%q)\n"):format(lua)
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
			-- !{ function sum(a, b) return a+b; end }
			-- local text = !{"Hello, mr. "..getName()}
			elseif
				tok.type == "pp_entry"
				and tokens[tokenIndex+1]
				and tokens[tokenIndex+1].type == "punctuation"
				and tokens[tokenIndex+1].value == "{"
			then
				local startPos = tok.position
				tokenIndex = tokenIndex+2 -- Jump past "!{".

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

					if tok.type == "punctuation" and tok.value == "{" then
						depth = depth+1

					elseif tok.type == "punctuation" and tok.value == "}" then
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

	local pathMeta = path:gsub("%.lua2p$", ".meta.lua")
	local luaParts = {}

	local metaEnv = {}
	for k, v in pairs(_G) do  metaEnv[k] = v  end
	metaEnv._G = metaEnv



	-- printf()
	--   Print a formatted string.
	--   printf( format, value1, ... )
	metaEnv.printf = printf

	-- outputValue()
	--   Output a formatted value, like strings or numbers.
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
				table.insert(luaParts, (("%q"):format(v):gsub("\\\n", "\\n")))

			elseif vType == "number" or vType == "boolean" or v == nil then
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
		table.insert(luaParts, lua)
	end

	-- run()
	--   Shorthand for loadfile().
	--   returnValue = run( filepath )
	function metaEnv.run(path)
		local chunk, err = loadfile(path)
		if not chunk then
			errorline(err)
		end

		return (chunk())
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
	chunk()

	local lua = table.concat(luaParts)
	--[[ :PrintCode
	print("=OUTPUT=============================")
	print(lua)
	print("====================================")
	--]]

	-- Write output file.
	----------------------------------------------------------------

	local pathOut = path:gsub("%.lua2p$", ".lua")
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

	printf("Processing '%s'... done!", path)
	printf(("-"):rep(#header))
end

print("All done!")
