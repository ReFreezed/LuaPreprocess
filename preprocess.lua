--[[============================================================
--=
--=  LuaPreprocess v1.21 - preprocessing library
--=  by Marcus 'ReFreezed' Thunström
--=
--=  License: MIT (see the bottom of this file)
--=  Website: http://refreezed.com/luapreprocess/
--=  Documentation: http://refreezed.com/luapreprocess/docs/
--=
--=  Tested with Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.
--=
--==============================================================

	API:

	Global functions in metaprograms:
	- copyTable
	- escapePattern
	- getIndentation
	- isProcessing
	- pack
	- pairsSorted
	- printf
	- readFile, writeFile, fileExists
	- run
	- sortNatural, compareNatural
	- tokenize, newToken, concatTokens, removeUselessTokens, eachToken, isToken, getNextUsefulToken
	- toLua, serialize, evaluate
	Only during processing:
	- getCurrentPathIn, getCurrentPathOut
	- getOutputSoFar, getOutputSoFarOnLine, getOutputSizeSoFar, getCurrentLineNumberInOutput, getCurrentIndentationInOutput
	- loadResource, callMacro
	- outputValue, outputLua, outputLuaTemplate
	- startInterceptingOutput, stopInterceptingOutput
	Macros:
	- ASSERT
	- LOG
	Search this file for 'EnvironmentTable' and 'PredefinedMacros' for more info.

	Exported stuff from the library:
	- (all the functions above)
	- VERSION
	- metaEnvironment
	- processFile, processString
	Search this file for 'ExportTable' for more info.

----------------------------------------------------------------

	How to metaprogram:

	The exclamation mark (!) is used to indicate what code is part of
	the metaprogram. There are 4 main ways to write metaprogram code:

	!...     The line will simply run during preprocessing. The line can span multiple actual lines if it contains brackets.
	!!...    The line will appear in both the metaprogram and the final program. The line must be an assignment.
	!(...)   The result of the parenthesis will be outputted as a literal if it's an expression, otherwise it'll just run.
	!!(...)  The result of the expression in the parenthesis will be outputted as Lua code. The result must be a string.

	Short examples:

	!if not isDeveloper then
		sendTelemetry()
	!end

	!!local tau = 2*math.pi -- The expression will be evaluated in the metaprogram and the result will appear in the final program as a literal.

	local bigNumber = !(5^10)

	local font = !!(isDeveloper and "loadDevFont()" or "loadUserFont()")

	-- See the full documentation for additional features (like macros):
	-- http://refreezed.com/luapreprocess/docs/extra-functionality/

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
	!newClass{ -- Starts here.
		name  = "Entity",
		props = {x=0, y=0},
	} -- Ends here.

	-- Preprocessor block.
	!(
	local dogWord = "Woof "
	function getDogText()
		return dogWord:rep(3)
	end
	)

	-- Preprocessor inline block. (Expression that returns a value.)
	local text = !("The dog said: "..getDogText())

	-- Preprocessor inline block variant. (Expression that returns a Lua code string.)
	_G.!!("myRandomGlobal"..math.random(5)) = 99

	-- Dual code (both preprocessor line and final output).
	!!local partial = "Hello"
	local   whole   = partial .. !(partial..", world!")
	print(whole) -- HelloHello, world!

	-- Beware in preprocessor blocks that only call a single function!
	!( func()  ) -- This will bee seen as an inline block and output whatever value func() returns as a literal.
	!( func(); ) -- If that's not wanted then a trailing `;` will prevent that. This line won't output anything by itself.
	-- When the full metaprogram is generated, `!(func())` translates into `outputValue(func())`
	-- while `!(func();)` simply translates into `func();` (because `outputValue(func();)` would be invalid Lua code).
	-- Though in this specific case a preprocessor line (without the parenthesis) would be nicer:
	!func()

	-- For the full documentation, see:
	-- http://refreezed.com/luapreprocess/docs/

--============================================================]]



local PP_VERSION = "1.21.0"

local MAX_DUPLICATE_FILE_INSERTS  = 1000 -- @Incomplete: Make this a parameter for processFile()/processString().
local MAX_CODE_LENGTH_IN_MESSAGES = 60

local KEYWORDS = {
	"and","break","do","else","elseif","end","false","for","function","if","in",
	"local","nil","not","or","repeat","return","then","true","until","while",
	-- Lua 5.2
	"goto", -- @Incomplete: A parameter to disable this for Lua 5.1?
} for i, v in ipairs(KEYWORDS) do  KEYWORDS[v], KEYWORDS[i] = true, nil  end

local PREPROCESSOR_KEYWORDS = {
	"file","insert","line",
} for i, v in ipairs(PREPROCESSOR_KEYWORDS) do  PREPROCESSOR_KEYWORDS[v], PREPROCESSOR_KEYWORDS[i] = true, nil  end

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

local ESCAPE_SEQUENCES_EXCEPT_QUOTES = {
	["\a"] = [[\a]],
	["\b"] = [[\b]],
	["\f"] = [[\f]],
	["\n"] = [[\n]],
	["\r"] = [[\r]],
	["\t"] = [[\t]],
	["\v"] = [[\v]],
	["\\"] = [[\\]],
}
local ESCAPE_SEQUENCES = {
	["\""] = [[\"]],
	["\'"] = [[\']],
} for k, v in pairs(ESCAPE_SEQUENCES_EXCEPT_QUOTES) do  ESCAPE_SEQUENCES[k] = v  end

local USELESS_TOKENS = {whitespace=true, comment=true}

local LOG_LEVELS = {
	["off"    ] = 0,
	["error"  ] = 1,
	["warning"] = 2,
	["info"   ] = 3,
	["debug"  ] = 4,
	["trace"  ] = 5,
}

local metaEnv  = nil
local dummyEnv = {}

-- Controlled by processFileOrString():
local current_parsingAndMeta_isProcessing = false
local current_parsingAndMeta_isDebug      = false

-- Controlled by _processFileOrString():
local current_anytime_isRunningMeta               = false
local current_anytime_pathIn                      = ""
local current_anytime_pathOut                     = ""
local current_anytime_fastStrings                 = false
local current_parsing_insertCount                 = 0
local current_parsingAndMeta_onInsert             = nil
local current_parsingAndMeta_resourceCache        = nil
local current_parsingAndMeta_addLineNumbers       = false
local current_parsingAndMeta_macroPrefix          = ""
local current_parsingAndMeta_macroSuffix          = ""
local current_parsingAndMeta_strictMacroArguments = true
local current_meta_pathForErrorMessages           = ""
local current_meta_output                         = nil -- Top item in current_meta_outputStack.
local current_meta_outputStack                    = nil
local current_meta_canOutputNil                   = true
local current_meta_releaseMode                    = false
local current_meta_maxLogLevel                    = "trace"
local current_meta_locationTokens                 = nil



--==============================================================
--= Local Functions ============================================
--==============================================================

local assertarg
local countString, countSubString
local getLineNumber
local loadLuaString
local maybeOutputLineNumber
local sortNatural
local tableInsert, tableRemove, tableInsertFormat
local utf8GetCodepointAndLength



local F = string.format

local function tryToFormatError(err0)
	local err, path, ln = nil

	if type(err0) == "string" then
		do               path, ln, err = err0:match"^(%a:[%w_/\\.]+):(%d+): (.*)"
		if not err then  path, ln, err = err0:match"^([%w_/\\.]+):(%d+): (.*)"
		if not err then  path, ln, err = err0:match"^(%S-):(%d+): (.*)"
		end end end
	end

	if err then
		return F("Error @ %s:%s: %s", path, ln, err)
	else
		return "Error: "..tostring(err0)
	end
end



local function printf(s, ...)
	print(F(s, ...))
end

-- printTokens( tokens [, filterUselessTokens ] )
local function printTokens(tokens, filter)
	for i, tok in ipairs(tokens) do
		if not (filter and USELESS_TOKENS[tok.type]) then
			printf("%d  %-12s '%s'", i, tok.type, (F("%q", tostring(tok.value)):sub(2, -2):gsub("\\\n", "\\n")))
		end
	end
end

local function printError(s)
	io.stderr:write(s, "\n")
end
local function printfError(s, ...)
	printError(F(s, ...))
end

-- message = formatTraceback( [ level=1 ] )
local function formatTraceback(level)
	local buffer = {}
	tableInsert(buffer, "stack traceback:\n")

	level       = 1 + (level or 1)
	local stack = {}

	while level < 1/0 do
		local info = debug.getinfo(level, "nSl")
		if not info then  break  end

		local isFile     = info.source:find"^@" ~= nil
		local sourceName = (isFile and info.source:sub(2) or info.short_src)

		local subBuffer = {"\t"}
		tableInsertFormat(subBuffer, "%s:", sourceName)

		if info.currentline > 0 then
			tableInsertFormat(subBuffer, "%d:", info.currentline)
		end

		if (info.name or "") ~= "" then
			tableInsertFormat(subBuffer, " in '%s'", info.name)
		elseif info.what == "main" then
			tableInsert(subBuffer, " in main chunk")
		elseif info.what == "C" or info.what == "tail" then
			tableInsert(subBuffer, " ?")
		else
			tableInsertFormat(subBuffer, " in <%s:%d>", sourceName:gsub("^.*[/\\]", ""), info.linedefined)
		end

		tableInsert(stack, table.concat(subBuffer))
		level = level + 1
	end

	while stack[#stack] == "\t[C]: ?" do
		stack[#stack] = nil
	end

	for _, s in ipairs(stack) do
		tableInsert(buffer, s)
		tableInsert(buffer, "\n")
	end

	return table.concat(buffer)
end

-- printErrorTraceback( message [, level=1 ] )
local function printErrorTraceback(message, level)
	printError(tryToFormatError(message))
	printError(formatTraceback(1+(level or 1)))
end

-- debugExit( )
-- debugExit( messageValue )
-- debugExit( messageFormat, ... )
local function debugExit(...)
	if select("#", ...) > 1 then
		printfError(...)
	elseif select("#", ...) == 1 then
		printError(...)
	end
	os.exit(2)
end



-- errorf( [ level=1, ] string, ... )
local function errorf(sOrLevel, ...)
	if type(sOrLevel) == "number" then
		error(F(...), (sOrLevel == 0 and 0 or 1+sOrLevel))
	else
		error(F(sOrLevel, ...), 2)
	end
end

-- local function errorLine(err) -- Unused.
-- 	if type(err) ~= "string" then  error(err)  end
-- 	error("\0"..err, 0) -- The 0 tells our own error handler not to print the traceback.
-- end
local function errorfLine(s, ...)
	errorf(0, (current_parsingAndMeta_isProcessing and "\0" or "")..s, ...) -- The \0 tells our own error handler not to print the traceback.
end

-- errorOnLine( path, lineNumber, agent=nil, s, ... )
local function errorOnLine(path, ln, agent, s, ...)
	s = F(s, ...)
	if agent then
		errorfLine("%s:%d: [%s] %s", path, ln, agent, s)
	else
		errorfLine("%s:%d: %s",      path, ln,        s)
	end
end

local errorInFile, runtimeErrorInFile
do
	local function findStartOfLine(s, pos, canBeEmpty)
		while pos > 1 do
			if s:byte(pos-1) == 10--[[\n]] and (canBeEmpty or s:byte(pos) ~= 10--[[\n]]) then  break  end
			pos = pos - 1
		end
		return math.max(pos, 1)
	end
	local function findEndOfLine(s, pos)
		while pos < #s do
			if s:byte(pos+1) == 10--[[\n]] then  break  end
			pos = pos + 1
		end
		return math.min(pos, #s)
	end

	local function _errorInFile(level, contents, path, pos, agent, s, ...)
		s = F(s, ...)

		pos      = math.min(math.max(pos, 1), #contents+1)
		local ln = getLineNumber(contents, pos)

		local lineStart     = findStartOfLine(contents, pos, true)
		local lineEnd       = findEndOfLine  (contents, pos-1)
		local linePre1Start = findStartOfLine(contents, lineStart-1, false)
		local linePre1End   = findEndOfLine  (contents, linePre1Start-1)
		local linePre2Start = findStartOfLine(contents, linePre1Start-1, false)
		local linePre2End   = findEndOfLine  (contents, linePre2Start-1)
		-- printfError("pos %d | lines %d..%d, %d..%d, %d..%d", pos, linePre2Start,linePre2End+1, linePre1Start,linePre1End+1, lineStart,lineEnd+1) -- DEBUG

		errorOnLine(path, ln, agent, "%s\n>\n%s%s%s>-%s^%s",
			s,
			(linePre2Start < linePre1Start and linePre2Start <= linePre2End) and F("> %s\n", (contents:sub(linePre2Start, linePre2End):gsub("\t", "    "))) or "",
			(linePre1Start < lineStart     and linePre1Start <= linePre1End) and F("> %s\n", (contents:sub(linePre1Start, linePre1End):gsub("\t", "    "))) or "",
			(                                  lineStart     <= lineEnd    ) and F("> %s\n", (contents:sub(lineStart,     lineEnd    ):gsub("\t", "    "))) or ">\n",
			("-"):rep(pos - lineStart + 3*countSubString(contents, lineStart, lineEnd, "\t", true)),
			(level and "\n"..formatTraceback(1+level) or "")
		)
	end

	-- errorInFile( contents, path, pos, agent, s, ... )
	--[[local]] function errorInFile(...)
		_errorInFile(nil, ...)
	end

	-- runtimeErrorInFile( level, contents, path, pos, agent, s, ... )
	--[[local]] function runtimeErrorInFile(level, ...)
		_errorInFile(1+level, ...)
	end
end

-- errorAtToken( token, position=token.position, agent, s, ... )
local function errorAtToken(tok, pos, agent, s, ...)
	-- printErrorTraceback("errorAtToken", 2) -- DEBUG
	errorInFile(current_parsingAndMeta_resourceCache[tok.file], tok.file, (pos or tok.position), agent, s, ...)
end

-- errorAfterToken( token, agent, s, ... )
local function errorAfterToken(tok, agent, s, ...)
	-- printErrorTraceback("errorAfterToken", 2) -- DEBUG
	errorInFile(current_parsingAndMeta_resourceCache[tok.file], tok.file, tok.position+#tok.representation, agent, s, ...)
end

-- runtimeErrorAtToken( level, token, position=token.position, agent, s, ... )
local function runtimeErrorAtToken(level, tok, pos, agent, s, ...)
	-- printErrorTraceback("runtimeErrorAtToken", 2) -- DEBUG
	runtimeErrorInFile(1+level, current_parsingAndMeta_resourceCache[tok.file], tok.file, (pos or tok.position), agent, s, ...)
end

-- internalError( [ message|value ] )
local function internalError(message)
	message = message and " ("..tostring(message)..")" or ""
	error("Internal error."..message, 2)
end



local function cleanError(err)
	if type(err) == "string" then
		err = err:gsub("%z", "")
	end
	return err
end



local function formatCodeForShortMessage(lua)
	lua = lua:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")

	if #lua > MAX_CODE_LENGTH_IN_MESSAGES then
		lua = lua:sub(1, MAX_CODE_LENGTH_IN_MESSAGES/2) .. "..." .. lua:sub(-MAX_CODE_LENGTH_IN_MESSAGES/2)
	end

	return lua
end



local ERROR_UNFINISHED_STRINGLIKE = 1

local function parseStringlikeToken(s, ptr)
	local reprStart = ptr
	local reprEnd

	local valueStart
	local valueEnd

	local longEqualSigns = s:match("^%[(=*)%[", ptr)
	local isLong         = longEqualSigns ~= nil

	-- Single line.
	if not isLong then
		valueStart = ptr

		local i = s:find("\n", ptr, true)
		if not i then
			reprEnd  = #s
			valueEnd = #s
			ptr      = reprEnd + 1
		else
			reprEnd  = i
			valueEnd = i - 1
			ptr      = reprEnd + 1
		end

	-- Multiline.
	else
		ptr        = ptr + 1 + #longEqualSigns + 1
		valueStart = ptr

		local i1, i2 = s:find("]"..longEqualSigns.."]", ptr, true)
		if not i1 then
			return nil, ERROR_UNFINISHED_STRINGLIKE
		end

		reprEnd  = i2
		valueEnd = i1 - 1
		ptr      = reprEnd + 1
	end

	local repr = s:sub(reprStart,  reprEnd)
	local v    = s:sub(valueStart, valueEnd)
	local tok  = {type="stringlike", representation=repr, value=v, long=isLong}

	return tok, ptr
end



local NUM_HEX_FRAC_EXP = ("^( 0[Xx] (%x*) %.(%x+) [Pp]([-+]?%x+) )"):gsub(" +", "")
local NUM_HEX_FRAC     = ("^( 0[Xx] (%x*) %.(%x+)                )"):gsub(" +", "")
local NUM_HEX_EXP      = ("^( 0[Xx] (%x+) %.?     [Pp]([-+]?%x+) )"):gsub(" +", "")
local NUM_HEX          = ("^( 0[Xx]  %x+  %.?                    )"):gsub(" +", "")
local NUM_DEC_FRAC_EXP = ("^(        %d*  %.%d+   [Ee][-+]?%d+   )"):gsub(" +", "")
local NUM_DEC_FRAC     = ("^(        %d*  %.%d+                  )"):gsub(" +", "")
local NUM_DEC_EXP      = ("^(        %d+  %.?     [Ee][-+]?%d+   )"):gsub(" +", "")
local NUM_DEC          = ("^(        %d+  %.?                    )"):gsub(" +", "")

-- tokens = _tokenize( luaString, path, allowPreprocessorTokens, allowBacktickStrings, allowJitSyntax )
local function _tokenize(s, path, allowPpTokens, allowBacktickStrings, allowJitSyntax)
	s = s:gsub("\r", "") -- Normalize line breaks. (Assume the input is either "\n" or "\r\n".)

	local tokens = {}
	local ptr    = 1
	local ln     = 1

	while ptr <= #s do
		local tok
		local tokenPos = ptr

		-- Whitespace.
		if s:find("^%s", ptr) then
			local i1, i2, whitespace = s:find("^(%s+)", ptr)

			ptr = i2+1
			tok = {type="whitespace", representation=whitespace, value=whitespace}

		-- Identifier/keyword.
		elseif s:find("^[%a_]", ptr) then
			local i1, i2, word = s:find("^([%a_][%w_]*)", ptr)
			ptr = i2+1

			if KEYWORDS[word] then
				tok = {type="keyword",    representation=word, value=word}
			else
				tok = {type="identifier", representation=word, value=word}
			end

		-- Number (binary).
		elseif s:find("^0b", ptr) then
			if not allowJitSyntax then
				errorInFile(s, path, ptr, "Tokenizer", "Encountered binary numeral. (Feature not enabled.)")
			end

			local i1, i2, numStr = s:find("^(..[01]+)", ptr)

			-- @Copypaste from below.
			if not numStr then
				errorInFile(s, path, ptr, "Tokenizer", "Malformed number.")
			end

			local numStrFallback = numStr

			do
				if s:find("^[Ii]", i2+1) then -- Imaginary part of complex number.
					numStr = s:sub(i1, i2+1)
					i2     = i2 + 1

				elseif s:find("^[Uu][Ll][Ll]", i2+1) then -- Unsigned 64-bit integer.
					numStr = s:sub(i1, i2+3)
					i2     = i2 + 3
				elseif s:find("^[Ll][Ll]", i2+1) then -- Signed 64-bit integer.
					numStr = s:sub(i1, i2+2)
					i2     = i2 + 2
				end
			end

			local n = tonumber(numStr) or tonumber(numStrFallback)

			if not n then
				errorInFile(s, path, ptr, "Tokenizer", "Invalid number.")
			end

			if s:find("^[%w_]", i2+1) then
				-- This is actually not an error in Lua 5.2 and 5.3. Maybe we should issue a warning instead of an error here?
				errorInFile(s, path, i2+1, "Tokenizer", "Malformed number.")
			end

			ptr = i2 + 1
			tok = {type="number", representation=numStrFallback, value=n}

		-- Number.
		elseif s:find("^%.?%d", ptr) then
			local           pat, maybeInt, lua52Hex, i1, i2, numStr = NUM_HEX_FRAC_EXP, false, true , s:find(NUM_HEX_FRAC_EXP, ptr)
			if not i1 then  pat, maybeInt, lua52Hex, i1, i2, numStr = NUM_HEX_FRAC    , false, true , s:find(NUM_HEX_FRAC    , ptr)
			if not i1 then  pat, maybeInt, lua52Hex, i1, i2, numStr = NUM_HEX_EXP     , false, true , s:find(NUM_HEX_EXP     , ptr)
			if not i1 then  pat, maybeInt, lua52Hex, i1, i2, numStr = NUM_HEX         , true , false, s:find(NUM_HEX         , ptr)
			if not i1 then  pat, maybeInt, lua52Hex, i1, i2, numStr = NUM_DEC_FRAC_EXP, false, false, s:find(NUM_DEC_FRAC_EXP, ptr)
			if not i1 then  pat, maybeInt, lua52Hex, i1, i2, numStr = NUM_DEC_FRAC    , false, false, s:find(NUM_DEC_FRAC    , ptr)
			if not i1 then  pat, maybeInt, lua52Hex, i1, i2, numStr = NUM_DEC_EXP     , false, false, s:find(NUM_DEC_EXP     , ptr)
			if not i1 then  pat, maybeInt, lua52Hex, i1, i2, numStr = NUM_DEC         , true , false, s:find(NUM_DEC         , ptr)
			end end end end end end end

			if not numStr then
				errorInFile(s, path, ptr, "Tokenizer", "Malformed number.")
			end

			local numStrFallback = numStr

			if allowJitSyntax then
				if s:find("^[Ii]", i2+1) then -- Imaginary part of complex number.
					numStr = s:sub(i1, i2+1)
					i2     = i2 + 1

				elseif not maybeInt or numStr:find(".", 1, true) then
					-- void

				elseif s:find("^[Uu][Ll][Ll]", i2+1) then -- Unsigned 64-bit integer.
					numStr = s:sub(i1, i2+3)
					i2     = i2 + 3
				elseif s:find("^[Ll][Ll]", i2+1) then -- Signed 64-bit integer.
					numStr = s:sub(i1, i2+2)
					i2     = i2 + 2
				end
			end

			local n = tonumber(numStr) or tonumber(numStrFallback)

			-- Support hexadecimal floats in Lua 5.1.
			if not n and lua52Hex then
				-- Note: We know we're not running LuaJIT here as it supports hexadecimal floats, thus we use numStrFallback instead of numStr.
				local                                _, intStr, fracStr, expStr
				if     pat == NUM_HEX_FRAC_EXP then  _, intStr, fracStr, expStr = numStrFallback:match(NUM_HEX_FRAC_EXP)
				elseif pat == NUM_HEX_FRAC     then  _, intStr, fracStr         = numStrFallback:match(NUM_HEX_FRAC) ; expStr  = "0"
				elseif pat == NUM_HEX_EXP      then  _, intStr,          expStr = numStrFallback:match(NUM_HEX_EXP)  ; fracStr = ""
				else internalError() end

				n = tonumber(intStr, 16) or 0 -- intStr may be "".

				local fracValue = 1
				for i = 1, #fracStr do
					fracValue = fracValue/16
					n         = n+tonumber(fracStr:sub(i, i), 16)*fracValue
				end

				n = n*2^expStr:gsub("^+", "")
			end

			if not n then
				errorInFile(s, path, ptr, "Tokenizer", "Invalid number.")
			end

			if s:find("^[%w_]", i2+1) then
				-- This is actually not an error in Lua 5.2 and 5.3. Maybe we should issue a warning instead of an error here?
				errorInFile(s, path, i2+1, "Tokenizer", "Malformed number.")
			end

			ptr = i2+1
			tok = {type="number", representation=numStrFallback, value=n}

		-- Comment.
		elseif s:find("^%-%-", ptr) then
			local reprStart = ptr
			ptr = ptr+2

			tok, ptr = parseStringlikeToken(s, ptr)
			if not tok then
				local errCode = ptr
				if errCode == ERROR_UNFINISHED_STRINGLIKE then
					errorInFile(s, path, reprStart, "Tokenizer", "Unfinished long comment.")
				else
					errorInFile(s, path, reprStart, "Tokenizer", "Invalid comment.")
				end
			end

			if tok.long then
				-- Check for nesting of [[...]], which is deprecated in Lua.
				local chunk, err = loadLuaString("--"..tok.representation, "@", nil)

				if not chunk then
					local lnInString, luaErr = err:match'^:(%d+): (.*)'
					if luaErr then
						errorOnLine(path, getLineNumber(s, reprStart)+tonumber(lnInString)-1, "Tokenizer", "Malformed long comment. (%s)", luaErr)
					else
						errorInFile(s, path, reprStart, "Tokenizer", "Malformed long comment.")
					end
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

				elseif c == "\n" then
					-- Can't have unescaped newlines. Lua, this is a silly rule! @Ugh
					errorInFile(s, path, ptr, "Tokenizer", "Newlines must be escaped in strings.")

				else
					ptr = ptr+1
				end
			end

			local repr = s:sub(reprStart, reprEnd)

			local valueChunk = loadLuaString("return"..repr, nil, nil)
			if not valueChunk then
				errorInFile(s, path, reprStart, "Tokenizer", "Malformed string.")
			end

			local v = valueChunk()
			assert(type(v) == "string")

			tok = {type="string", representation=repr, value=valueChunk(), long=false}

		-- Long string.
		elseif s:find("^%[=*%[", ptr) then
			local reprStart = ptr

			tok, ptr = parseStringlikeToken(s, ptr)
			if not tok then
				local errCode = ptr
				if errCode == ERROR_UNFINISHED_STRINGLIKE then
					errorInFile(s, path, reprStart, "Tokenizer", "Unfinished long string.")
				else
					errorInFile(s, path, reprStart, "Tokenizer", "Invalid long string.")
				end
			end

			-- Check for nesting of [[...]], which is deprecated in Lua.
			local valueChunk, err = loadLuaString("return"..tok.representation, "@", nil)

			if not valueChunk then
				local lnInString, luaErr = err:match'^:(%d+): (.*)'
				if luaErr then
					errorOnLine(path, getLineNumber(s, reprStart)+tonumber(lnInString)-1, "Tokenizer", "Malformed long string. (%s)", luaErr)
				else
					errorInFile(s, path, reprStart, "Tokenizer", "Malformed long string.")
				end
			end

			local v = valueChunk()
			assert(type(v) == "string")

			tok.type  = "string"
			tok.value = v

		-- Backtick string.
		elseif s:find("^`", ptr) then
			if not allowBacktickStrings then
				errorInFile(s, path, ptr, "Tokenizer", "Encountered backtick string. (Feature not enabled.)")
			end

			local i1, i2, repr, v = s:find("^(`([^`]*)`)", ptr)
			if not i2 then
				errorInFile(s, path, ptr, "Tokenizer", "Unfinished backtick string.")
			end

			ptr = i2+1
			tok = {type="string", representation=repr, value=v, long=false}

		-- Punctuation etc.
		elseif s:find("^%.%.%.", ptr) then -- 3
			local repr = s:sub(ptr, ptr+2)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr
		elseif s:find("^%.%.", ptr) or s:find("^[=~<>]=", ptr) or s:find("^::", ptr) or s:find("^//", ptr) or s:find("^<<", ptr) or s:find("^>>", ptr) then -- 2
			local repr = s:sub(ptr, ptr+1)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr
		elseif s:find("^[+%-*/%%^#<>=(){}[%];:,.&|~]", ptr) then -- 1
			local repr = s:sub(ptr, ptr)
			tok = {type="punctuation", representation=repr, value=repr}
			ptr = ptr+#repr

		-- Preprocessor entry.
		elseif s:find("^!", ptr) then
			if not allowPpTokens then
				errorInFile(s, path, ptr, "Tokenizer", "Encountered preprocessor entry. (Feature not enabled.)")
			end

			local double = s:find("^!", ptr+1) ~= nil
			local repr   = s:sub(ptr, ptr+(double and 1 or 0))

			tok = {type="pp_entry", representation=repr, value=repr, double=double}
			ptr = ptr+#repr

		-- Preprocessor keyword.
		elseif s:find("^@", ptr) then
			if not allowPpTokens then
				errorInFile(s, path, ptr, "Tokenizer", "Encountered preprocessor keyword. (Feature not enabled.)")
			end

			if s:find("^@@", ptr) then
				ptr = ptr+2
				tok = {type="pp_keyword", representation="@@", value="insert"}
			else
				local i1, i2, repr, word = s:find("^(@([%a_][%w_]*))", ptr)
				if not i1 then
					errorInFile(s, path, ptr+1, "Tokenizer", "Expected an identifier.")
				elseif not PREPROCESSOR_KEYWORDS[word] then
					errorInFile(s, path, ptr+1, "Tokenizer", "Invalid preprocessor keyword '%s'.", word)
				end
				ptr = i2+1
				tok = {type="pp_keyword", representation=repr, value=word}
			end

		-- Preprocessor symbol.
		elseif s:find("^%$", ptr) then
			if not allowPpTokens then
				errorInFile(s, path, ptr, "Tokenizer", "Encountered preprocessor symbol. (Feature not enabled.)")
			end

			local i1, i2, repr, word = s:find("^(%$([%a_][%w_]*))", ptr)
			if not i1 then
				errorInFile(s, path, ptr+1, "Tokenizer", "Expected an identifier.")
			elseif KEYWORDS[word] then
				errorInFile(s, path, ptr+1, "Tokenizer", "Invalid preprocessor symbol '%s'. (Must not be a Lua keyword.)", word)
			end
			ptr = i2+1
			tok = {type="pp_symbol", representation=repr, value=word}

		else
			errorInFile(s, path, ptr, "Tokenizer", "Unknown character.")
		end

		tok.line     = ln
		tok.position = tokenPos
		tok.file     = path

		ln = ln+countString(tok.representation, "\n", true)
		tok.lineEnd = ln

		tableInsert(tokens, tok)
		-- print(#tokens, tok.type, tok.representation) -- DEBUG
	end

	return tokens
end



-- luaString = _concatTokens( tokens, lastLn=nil, addLineNumbers, fromIndex=1, toIndex=#tokens )
local function _concatTokens(tokens, lastLn, addLineNumbers, i1, i2)
	local parts = {}

	if addLineNumbers then
		for i = (i1 or 1), (i2 or #tokens) do
			local tok = tokens[i]
			lastLn    = maybeOutputLineNumber(parts, tok, lastLn)
			tableInsert(parts, tok.representation)
		end

	else
		for i = (i1 or 1), (i2 or #tokens) do
			tableInsert(parts, tokens[i].representation)
		end
	end

	return table.concat(parts)
end

local function insertTokenRepresentations(parts, tokens, i1, i2)
	for i = i1, i2 do
		tableInsert(parts, tokens[i].representation)
	end
end



local function readFile(path, isTextFile)
	assertarg(1, path,       "string")
	assertarg(2, isTextFile, "boolean","nil")

	local file, err = io.open(path, "r"..(isTextFile and "" or "b"))
	if not file then  return nil, err  end

	local contents = file:read"*a"
	file:close()
	return contents
end

-- success, error = writeFile( path, [ isTextFile=false, ] contents )
local function writeFile(path, isTextFile, contents)
	assertarg(1, path, "string")

	if type(isTextFile) == "boolean" then
		assertarg(3, contents, "string")
	else
		isTextFile, contents = false, isTextFile
		assertarg(2, contents, "string")
	end

	local file, err = io.open(path, "w"..(isTextFile and "" or "b"))
	if not file then  return false, err  end

	file:write(contents)
	file:close()
	return true
end

local function fileExists(path)
	assertarg(1, path, "string")

	local file = io.open(path, "r")
	if not file then  return false  end

	file:close()
	return true
end



-- assertarg( argumentNumber, value, expectedValueType1, ... )
--[[local]] function assertarg(n, v, ...)
	local vType = type(v)

	for i = 1, select("#", ...) do
		if vType == select(i, ...) then  return  end
	end

	local fName   = debug.getinfo(2, "n").name
	local expects = table.concat({...}, " or ")

	if fName == "" then  fName = "?"  end

	errorf(3, "bad argument #%d to '%s' (%s expected, got %s)", n, fName, expects, vType)
end



-- count = countString( haystack, needle [, plain=false ] )
--[[local]] function countString(s, needle, plain)
	local count = 0
	local i     = 0
	local _

	while true do
		_, i = s:find(needle, i+1, plain)
		if not i then  return count  end

		count = count+1
	end
end

-- count = countSubString( string, startPosition, endPosition, needle [, plain=false ] )
--[[local]] function countSubString(s, pos, posEnd, needle, plain)
	local count = 0

	while true do
		local _, i2 = s:find(needle, pos, plain)
		if not i2 or i2 > posEnd then  return count  end

		count = count + 1
		pos   = i2    + 1
	end
end



local getfenv = getfenv or function(f) -- Assume Lua is version 5.2+ if getfenv() doesn't exist.
	f = f or 1

	if type(f) == "function" then
		-- void

	elseif type(f) == "number" then
		if f == 0 then  return _ENV  end
		if f <  0 then  error("bad argument #1 to 'getfenv' (level must be non-negative)")  end

		f = debug.getinfo(1+f, "f") or error("bad argument #1 to 'getfenv' (invalid level)")
		f = f.func

	else
		error("bad argument #1 to 'getfenv' (number expected, got "..type(f)..")")
	end

	for i = 1, 1/0 do
		local name, v = debug.getupvalue(f, i)
		if name == "_ENV" then  return v     end
		if not name       then  return _ENV  end
	end
end



-- (Table generated by misc/generateStringEscapeSequenceInfo.lua)
local UNICODE_RANGES_NOT_TO_ESCAPE = {
	{from=32, to=126},
	{from=161, to=591},
	{from=880, to=887},
	{from=890, to=895},
	{from=900, to=906},
	{from=908, to=908},
	{from=910, to=929},
	{from=931, to=1154},
	{from=1162, to=1279},
	{from=7682, to=7683},
	{from=7690, to=7691},
	{from=7710, to=7711},
	{from=7744, to=7745},
	{from=7766, to=7767},
	{from=7776, to=7777},
	{from=7786, to=7787},
	{from=7808, to=7813},
	{from=7835, to=7835},
	{from=7922, to=7923},
	{from=8208, to=8208},
	{from=8210, to=8231},
	{from=8240, to=8286},
	{from=8304, to=8305},
	{from=8308, to=8334},
	{from=8336, to=8348},
	{from=8352, to=8383},
	{from=8448, to=8587},
	{from=8592, to=9254},
	{from=9312, to=10239},
	{from=10496, to=11007},
	{from=64256, to=64262},
}

local function shouldCodepointBeEscaped(cp)
	for _, range in ipairs(UNICODE_RANGES_NOT_TO_ESCAPE) do -- @Speed: Don't use a loop?
		if cp >= range.from and cp <= range.to then  return false  end
	end
	return true
end

-- local cache = setmetatable({}, {__mode="kv"}) -- :SerializationCache (This doesn't seem to speed things up.)

-- success, error = serialize( buffer, value )
local function serialize(buffer, v)
	--[[ :SerializationCache
	if cache[v] then
		tableInsert(buffer, cache[v])
		return true
	end
	local bufferStart = #buffer + 1
	--]]

	local vType       = type(v)

	if vType == "table" then
		local first = true
		tableInsert(buffer, "{")

		local indices = {}
		for i, item in ipairs(v) do
			if not first then  tableInsert(buffer, ",")  end
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
				tableInsert(keys, k)
			end
		end

		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)

		for _, k in ipairs(keys) do
			local item = v[k]

			if not first then  tableInsert(buffer, ",")  end
			first = false

			if not KEYWORDS[k] and type(k) == "string" and k:find"^[%a_][%w_]*$" then
				tableInsert(buffer, k)
				tableInsert(buffer, "=")

			else
				tableInsert(buffer, "[")

				local ok, err = serialize(buffer, k)
				if not ok then  return false, err  end

				tableInsert(buffer, "]=")
			end

			local ok, err = serialize(buffer, item)
			if not ok then  return false, err  end
		end

		tableInsert(buffer, "}")

	elseif vType == "string" then
		if v == "" then
			tableInsert(buffer, '""')
			return true
		end

		local useApostrophe = v:find('"', 1, true) and not v:find("'", 1, true)
		local quote         = useApostrophe and "'" or '"'

		tableInsert(buffer, quote)

		if current_anytime_fastStrings or not v:find"[^\32-\126\t\n]" then
			-- print(">> FAST", #v) -- DEBUG

			local s = v:gsub((useApostrophe and "[\t\n\\']" or '[\t\n\\"]'), function(c)
				return ESCAPE_SEQUENCES[c] or internalError(c:byte())
			end)
			tableInsert(buffer, s)

		else
			-- print(">> SLOW", #v) -- DEBUG
			local pos = 1

			-- @Speed: There are optimizations to be made here!
			while pos <= #v do
				local c       = v:sub(pos, pos)
				local cp, len = utf8GetCodepointAndLength(v, pos)

				-- Named escape sequences.
				if ESCAPE_SEQUENCES_EXCEPT_QUOTES[c] then  tableInsert(buffer, ESCAPE_SEQUENCES_EXCEPT_QUOTES[c])  ; pos = pos+1
				elseif c == quote                    then  tableInsert(buffer, [[\]]) ; tableInsert(buffer, quote) ; pos = pos+1

				-- UTF-8 character.
				elseif len == 1 and not shouldCodepointBeEscaped(cp) then  tableInsert(buffer, v:sub(pos, pos      )) ; pos = pos+1 -- @Speed: We can insert multiple single-byte characters sometimes!
				elseif len      and not shouldCodepointBeEscaped(cp) then  tableInsert(buffer, v:sub(pos, pos+len-1)) ; pos = pos+len

				-- Anything else.
				else
					tableInsert(buffer, F((v:find("^%d", pos+1) and "\\%03d" or "\\%d"), v:byte(pos)))
					pos = pos + 1
				end
			end
		end

		tableInsert(buffer, quote)

	elseif v == 1/0 then
		tableInsert(buffer, "(1/0)")
	elseif v == -1/0 then
		tableInsert(buffer, "(-1/0)")
	elseif v ~= v then
		tableInsert(buffer, "(0/0)") -- NaN.
	elseif v == 0 then
		tableInsert(buffer, "0") -- In case it's actually -0 for some reason, which would be silly to output.
	elseif vType == "number" then
		if v < 0 then
			tableInsert(buffer, " ") -- The space prevents an accidental comment if a "-" is right before.
		end
		tableInsert(buffer, tostring(v)) -- (I'm not sure what precision tostring() uses for numbers. Maybe we should use string.format() instead.)

	elseif vType == "boolean" or v == nil then
		tableInsert(buffer, tostring(v))

	else
		return false, F("Cannot serialize value of type '%s'. (%s)", vType, tostring(v))
	end

	--[[ :SerializationCache
	if v ~= nil then
		cache[v] = table.concat(buffer, "", bufferStart, #buffer)
	end
	--]]

	return true
end

-- luaString = toLua( value )
-- Returns nil and a message on error.
local function toLua(v)
	local buffer = {}

	local ok, err = serialize(buffer, v)
	if not ok then  return nil, err  end

	return table.concat(buffer)
end

-- value = evaluate( expression [, environment=getfenv() ] )
-- Returns nil and a message on error.
local function evaluate(expr, env)
	local chunk, err = loadLuaString("return("..expr.."\n)", "@<evaluate>", (env or getfenv(2)))
	if not chunk then
		return nil, F("Invalid expression '%s'. (%s)", expr, (err:gsub("^:%d+: ", "")))
	end

	local ok, valueOrErr = pcall(chunk)
	if not ok then  return nil, valueOrErr  end

	return valueOrErr -- May be nil or false!
end



local function escapePattern(s)
	return (s:gsub("[-+*^?$.%%()[%]]", "%%%0"))
end



local function outputLineNumber(parts, ln)
	tableInsert(parts, "--[[@")
	tableInsert(parts, ln)
	tableInsert(parts, "]]")
end

--[[local]] function maybeOutputLineNumber(parts, tok, lastLn)
	if tok.line == lastLn or USELESS_TOKENS[tok.type] then  return lastLn  end

	outputLineNumber(parts, tok.line)
	return tok.line
end
--[=[
--[[local]] function maybeOutputLineNumber(parts, tok, lastLn, fromMetaToOutput)
	if tok.line == lastLn or USELESS_TOKENS[tok.type] then  return lastLn  end

	if fromMetaToOutput then
		tableInsert(parts, '__LUA"--[[@'..tok.line..']]"\n')
	else
		tableInsert(parts, "--[[@"..tok.line.."]]")
	end
	return tok.line
end
]=]



local function isAny(v, ...)
	for i = 1, select("#", ...) do
		if v == select(i, ...) then  return true  end
	end
	return false
end



local function errorIfNotRunningMeta(level)
	if not current_anytime_isRunningMeta then
		error("No file is being processed.", 1+level)
	end
end



local function copyArray(t)
	local copy = {}
	for i, v in ipairs(t) do
		copy[i] = v
	end
	return copy
end

local copyTable
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

	-- copy = copyTable( table [, deep=false ] )
	--[[local]] function copyTable(t, deep)
		local copy = {}

		if deep then
			return deepCopy(t, copy, {[t]=copy})
		end

		for k, v in pairs(t) do  copy[k] = v  end

		return copy
	end
end



-- values = pack( value1, ... )
-- values.n is the amount of values (which can be zero).
local pack = (
	(_VERSION >= "Lua 5.2" or jit) and table.pack
	or function(...)
		return {n=select("#", ...), ...}
	end
)

local unpack = (_VERSION >= "Lua 5.2") and table.unpack or _G.unpack



--[[local]] loadLuaString = (
	(_VERSION >= "Lua 5.2" or jit) and function(lua, chunkName, env)
		return load(lua, chunkName, "bt", env)
	end
	or function(lua, chunkName, env)
		local chunk, err = loadstring(lua, chunkName)
		if not chunk then  return nil, err  end

		if env then  setfenv(chunk, env)  end

		return chunk
	end
)

local loadLuaFile = (
	(_VERSION >= "Lua 5.2" or jit) and function(path, env)
		return loadfile(path, "bt", env)
	end
	or function(path, env)
		local chunk, err = loadfile(path)
		if not chunk then  return nil, err  end

		if env then  setfenv(chunk, env)  end

		return chunk
	end
)

local function isLuaStringValidExpression(lua)
	return loadLuaString("return("..lua.."\n)", "@", nil) ~= nil
end



-- token, index = getNextUsableToken( tokens, startIndex, indexLimit=autoDependingOnDirection, direction )
local function getNextUsableToken(tokens, iStart, iLimit, dir)
	iLimit = (
		dir < 0
		and math.max((iLimit or 1  ), 1)
		or  math.min((iLimit or 1/0), #tokens)
	)

	for i = iStart, iLimit, dir do
		if not USELESS_TOKENS[tokens[i].type] then
			return tokens[i], i
		end
	end

	return nil
end



-- bool = isToken( token, tokenType [, tokenValue=any ] )
local function isToken(tok, tokType, v)
	return tok.type == tokType and (v == nil or tok.value == v)
end

-- bool = isTokenAndNotNil( token, tokenType [, tokenValue=any ] )
local function isTokenAndNotNil(tok, tokType, v)
	return tok ~= nil and tok.type == tokType and (v == nil or tok.value == v)
end



--[[local]] function getLineNumber(s, pos)
	return 1 + countSubString(s, 1, pos-1, "\n", true)
end



-- text = getRelativeLocationText( tokenOfInterest, otherToken )
-- text = getRelativeLocationText( tokenOfInterest, otherFilename, otherLineNumber )
local function getRelativeLocationText(tokOfInterest, otherFilename, otherLn)
	if type(otherFilename) == "table" then
		return getRelativeLocationText(tokOfInterest, otherFilename.file, otherFilename.line)
	end

	if not (tokOfInterest.file and tokOfInterest.line) then
		return "at <UnknownLocation>"
	end

	if tokOfInterest.file   ~= otherFilename then  return F("at %s:%d", tokOfInterest.file, tokOfInterest.line)  end
	if tokOfInterest.line+1 == otherLn       then  return F("on the previous line")  end
	if tokOfInterest.line-1 == otherLn       then  return F("on the next line")  end
	if tokOfInterest.line   ~= otherLn       then  return F("on line %d", tokOfInterest.line)  end
	return "on the same line"
end



--[[local]] tableInsert = table.insert
--[[local]] tableRemove = table.remove

--[[local]] function tableInsertFormat(t, s, ...)
	tableInsert(t, F(s, ...))
end



-- length|nil = utf8GetCharLength( string [, position=1 ] )
local function utf8GetCharLength(s, pos)
	pos                  = pos or 1
	local b1, b2, b3, b4 = s:byte(pos, pos+3)

	if b1 > 0 and b1 <= 127 then
		return 1

	elseif b1 >= 194 and b1 <= 223 then
		if not b2               then  return nil  end -- UTF-8 string terminated early.
		if b2 < 128 or b2 > 191 then  return nil  end -- Invalid UTF-8 character.
		return 2

	elseif b1 >= 224 and b1 <= 239 then
		if not b3                               then  return nil  end -- UTF-8 string terminated early.
		if b1 == 224 and (b2 < 160 or b2 > 191) then  return nil  end -- Invalid UTF-8 character.
		if b1 == 237 and (b2 < 128 or b2 > 159) then  return nil  end -- Invalid UTF-8 character.
		if               (b2 < 128 or b2 > 191) then  return nil  end -- Invalid UTF-8 character.
		if               (b3 < 128 or b3 > 191) then  return nil  end -- Invalid UTF-8 character.
		return 3

	elseif b1 >= 240 and b1 <= 244 then
		if not b4                               then  return nil  end -- UTF-8 string terminated early.
		if b1 == 240 and (b2 < 144 or b2 > 191) then  return nil  end -- Invalid UTF-8 character.
		if b1 == 244 and (b2 < 128 or b2 > 143) then  return nil  end -- Invalid UTF-8 character.
		if               (b2 < 128 or b2 > 191) then  return nil  end -- Invalid UTF-8 character.
		if               (b3 < 128 or b3 > 191) then  return nil  end -- Invalid UTF-8 character.
		if               (b4 < 128 or b4 > 191) then  return nil  end -- Invalid UTF-8 character.
		return 4
	end

	return nil -- Invalid UTF-8 character.
end

-- codepoint, length = utf8GetCodepointAndLength( string [, position=1 ] )
-- Returns nil if the text is invalid at the position.
--[[local]] function utf8GetCodepointAndLength(s, pos)
	pos       = pos or 1
	local len = utf8GetCharLength(s, pos)
	if not len then  return nil  end

	-- 2^6=64, 2^12=4096, 2^18=262144
	if len == 1 then                                              return                                              s:byte(pos), len  end
	if len == 2 then  local b1, b2         = s:byte(pos, pos+1) ; return                                   (b1-192)*64 + (b2-128), len  end
	if len == 3 then  local b1, b2, b3     = s:byte(pos, pos+2) ; return                   (b1-224)*4096 + (b2-128)*64 + (b3-128), len  end
	do                local b1, b2, b3, b4 = s:byte(pos, pos+3) ; return (b1-240)*262144 + (b2-128)*4096 + (b3-128)*64 + (b4-128), len  end
end



-- for k, v in pairsSorted( table ) do
local function pairsSorted(t)
	local keys = {}
	for k in pairs(t) do
		tableInsert(keys, k)
	end
	sortNatural(keys)

	local i = 0

	return function()
		i = i+1
		local k = keys[i]
		if k ~= nil then  return k, t[k]  end
	end
end



-- sortNatural( array )
-- aIsLessThanB = compareNatural( a, b )
local compareNatural
do
	local function pad(numStr)
		return F("%03d%s", #numStr, numStr)
	end
	--[[local]] function compareNatural(a, b)
		if type(a) == "number" and type(b) == "number" then
			return a < b
		else
			return (tostring(a):gsub("%d+", pad) < tostring(b):gsub("%d+", pad))
		end
	end

	--[[local]] function sortNatural(t, k)
		table.sort(t, compareNatural)
	end
end



-- lua = _loadResource( resourceName, isParsing==true , nameToken, stats ) -- At parse time.
-- lua = _loadResource( resourceName, isParsing==false, errorLevel       ) -- At metaprogram runtime.
local function _loadResource(resourceName, isParsing, nameTokOrErrLevel, stats)
	local lua = current_parsingAndMeta_resourceCache[resourceName]

	if not lua then
		if current_parsingAndMeta_onInsert then
			lua = current_parsingAndMeta_onInsert(resourceName)

			if type(lua) == "string" then
				-- void
			elseif isParsing then
				errorAtToken(nameTokOrErrLevel, nameTokOrErrLevel.position+1, "Parser/MetaProgram", "Expected a string from params.onInsert(). (Got %s)", type(lua))
			else
				errorf(1+nameTokOrErrLevel, "Expected a string from params.onInsert(). (Got %s)", type(lua))
			end

		else
			local err
			lua, err = readFile(resourceName, true)

			if lua then
				-- void
			elseif isParsing then
				errorAtToken(nameTokOrErrLevel, nameTokOrErrLevel.position+1, "Parser", "Could not read file '%s'. (%s)", resourceName, tostring(err))
			else
				errorf(1+nameTokOrErrLevel, "Could not read file '%s'. (%s)", resourceName, tostring(err))
			end
		end

		current_parsingAndMeta_resourceCache[resourceName] = lua

		if isParsing then
			tableInsert(stats.insertedNames, resourceName)
		end

	elseif isParsing then
		current_parsing_insertCount = current_parsing_insertCount + 1 -- Note: We don't count insertions of newly encountered files.

		if current_parsing_insertCount > MAX_DUPLICATE_FILE_INSERTS then
			errorAtToken(
				nameTokOrErrLevel, nameTokOrErrLevel.position+1, "Parser",
				"Too many duplicate inserts. We may be stuck in a recursive loop. (Unique files inserted so far: %s)",
				stats.insertedNames[1] and table.concat(stats.insertedNames, ", ") or "none"
			)
		end
	end

	return lua
end



--==============================================================
--= Preprocessor Functions =====================================
--==============================================================



-- :EnvironmentTable
----------------------------------------------------------------

metaEnv    = copyTable(_G) -- Include all standard Lua stuff.
metaEnv._G = metaEnv

local metaFuncs = {}

-- printf()
--   printf( format, value1, ... )
--   Print a formatted string to stdout.
metaFuncs.printf = printf

-- readFile()
--   contents = readFile( path [, isTextFile=false ] )
--   Get the entire contents of a binary file or text file. Returns nil and a message on error.
metaFuncs.readFile        = readFile
metaFuncs.getFileContents = readFile -- @Deprecated

-- writeFile()
--   success, error = writeFile( path, contents ) -- Writes a binary file.
--   success, error = writeFile( path, isTextFile, contents )
--   Write an entire binary file or text file.
metaFuncs.writeFile = writeFile

-- fileExists()
--   bool = fileExists( path )
--   Check if a file exists.
metaFuncs.fileExists = fileExists

-- toLua()
--   luaString = toLua( value )
--   Convert a value to a Lua literal. Does not work with certain types, like functions or userdata.
--   Returns nil and a message on error.
metaFuncs.toLua = toLua

-- serialize()
--   success, error = serialize( buffer, value )
--   Same as toLua() except adds the result to an array instead of returning the Lua code as a string.
--   This could avoid allocating unnecessary strings.
metaFuncs.serialize = serialize

-- evaluate()
--   value = evaluate( expression [, environment=getfenv() ] )
--   Evaluate a Lua expression. The function is kind of the opposite of toLua(). Returns nil and a message on error.
--   Note that nil or false can also be returned as the first value if that's the value the expression results in!
metaFuncs.evaluate = evaluate

-- escapePattern()
--   escapedString = escapePattern( string )
--   Escape a string so it can be used in a pattern as plain text.
metaFuncs.escapePattern = escapePattern

-- isToken()
--   bool = isToken( token, tokenType [, tokenValue=any ] )
--   Check if a token is of a specific type, optionally also check it's value.
metaFuncs.isToken = isToken

-- copyTable()
--   copy = copyTable( table [, deep=false ] )
--   Copy a table, optionally recursively (deep copy).
--   Multiple references to the same table and self-references are preserved during deep copying.
metaFuncs.copyTable = copyTable

-- unpack()
--   value1, ... = unpack( array [, fromIndex=1, toIndex=#array ] )
--   Is _G.unpack() in Lua 5.1 and alias for table.unpack() in Lua 5.2+.
metaFuncs.unpack = unpack

-- pack()
--   values = pack( value1, ... )
--   Put values in a new array. values.n is the amount of values (which can be zero)
--   including nil values. Alias for table.pack() in Lua 5.2+.
metaFuncs.pack = pack

-- pairsSorted()
--   for key, value in pairsSorted( table ) do
--   Same as pairs() but the keys are sorted (ascending).
metaFuncs.pairsSorted = pairsSorted

-- sortNatural()
--   sortNatural( array )
--   Sort an array using compareNatural().
metaFuncs.sortNatural = sortNatural

-- compareNatural()
--   aIsLessThanB = compareNatural( a, b )
--   Compare two strings. Numbers in the strings are compared as numbers (as opposed to as strings).
--   Examples:
--     print(               "foo9" < "foo10" ) -- false
--     print(compareNatural("foo9",  "foo10")) -- true
metaFuncs.compareNatural = compareNatural

-- run()
--   returnValue1, ... = run( path [, arg1, ... ] )
--   Execute a Lua file. Similar to dofile().
function metaFuncs.run(path, ...)
	assertarg(1, path, "string")

	local main_chunk, err = loadLuaFile(path, metaEnv)
	if not main_chunk then  error(err, 0)  end

	-- We want multiple return values while avoiding a tail call to preserve stack info.
	local returnValues = pack(main_chunk(...))
	return unpack(returnValues, 1, returnValues.n)
end

-- outputValue()
--   outputValue( value )
--   outputValue( value1, value2, ... ) -- Outputted values will be separated by commas.
--   Output one or more values, like strings or tables, as literals.
--   Raises an error if no file or string is being processed.
function metaFuncs.outputValue(...)
	errorIfNotRunningMeta(2)

	local argCount = select("#", ...)
	if argCount == 0 then
		error("No values to output.", 2)
	end

	for i = 1, argCount do
		local v = select(i, ...)

		if v == nil and not current_meta_canOutputNil then
			local ln = debug.getinfo(2, "l").currentline
			errorOnLine(current_meta_pathForErrorMessages, ln, "MetaProgram", "Trying to output nil which is disallowed through params.canOutputNil .")
		end

		if i > 1 then
			tableInsert(current_meta_output, (current_parsingAndMeta_isDebug and ", " or ","))
		end

		local ok, err = serialize(current_meta_output, v)

		if not ok then
			local ln = debug.getinfo(2, "l").currentline
			errorOnLine(current_meta_pathForErrorMessages, ln, "MetaProgram", "%s", err)
		end
	end
end

-- outputLua()
--   outputLua( luaString1, ... )
--   Output one or more strings as raw Lua code.
--   Raises an error if no file or string is being processed.
function metaFuncs.outputLua(...)
	errorIfNotRunningMeta(2)

	local argCount = select("#", ...)
	if argCount == 0 then
		error("No Lua code to output.", 2)
	end

	for i = 1, argCount do
		local lua = select(i, ...)
		assertarg(i, lua, "string")
		tableInsert(current_meta_output, lua)
	end
end

-- outputLuaTemplate()
--   outputLuaTemplate( luaStringTemplate, value1, ... )
--   Use a string as a template for outputting Lua code with values.
--   Question marks (?) are replaced with the values.
--   Raises an error if no file or string is being processed.
--   Examples:
--     outputLuaTemplate("local name, age = ?, ?", "Harry", 48)
--     outputLuaTemplate("dogs[?] = ?", "greyhound", {italian=false, count=5})
function metaFuncs.outputLuaTemplate(lua, ...)
	errorIfNotRunningMeta(2)
	assertarg(1, lua, "string")

	local args = {...} -- @Memory
	local n    = 0
	local v, err

	lua = lua:gsub("%?", function()
		n      = n + 1
		v, err = toLua(args[n])

		if not v then
			errorf(3, "Bad argument %d: %s", 1+n, err)
		end

		return v
	end)

	tableInsert(current_meta_output, lua)
end

-- getOutputSoFar()
--   luaString = getOutputSoFar( [ asTable=false ] )
--   getOutputSoFar( buffer )
--   Get Lua code that's been outputted so far.
--   If asTable is false then the full Lua code string is returned.
--   If asTable is true then an array of Lua code segments is returned. (This avoids allocating, possibly large, strings.)
--   If a buffer array is given then Lua code segments are added to it.
--   Raises an error if no file or string is being processed.
function metaFuncs.getOutputSoFar(bufferOrAsTable)
	errorIfNotRunningMeta(2)

	-- Should there be a way to get the contents of current_meta_output etc.? :GetMoreOutputFromStack

	if type(bufferOrAsTable) == "table" then
		for _, lua in ipairs(current_meta_outputStack[1]) do
			tableInsert(bufferOrAsTable, lua)
		end
		-- Return nothing!

	else
		return bufferOrAsTable and copyArray(current_meta_outputStack[1]) or table.concat(current_meta_outputStack[1])
	end
end

local lineFragments = {}

local function getOutputSoFarOnLine()
	errorIfNotRunningMeta(2)

	local len = 0

	-- Should there be a way to get the contents of current_meta_output etc.? :GetMoreOutputFromStack
	for i = #current_meta_outputStack[1], 1, -1 do
		local fragment = current_meta_outputStack[1][i]

		if fragment:find("\n", 1, true) then
			len                = len + 1
			lineFragments[len] = fragment:gsub(".*\n", "")
			break
		end

		len                = len + 1
		lineFragments[len] = fragment
	end

	return table.concat(lineFragments, 1, len)
end

-- getOutputSoFarOnLine()
--   luaString = getOutputSoFarOnLine( )
--   Get Lua code that's been outputted so far on the current line.
--   Raises an error if no file or string is being processed.
metaFuncs.getOutputSoFarOnLine = getOutputSoFarOnLine

-- getOutputSizeSoFar()
--   size = getOutputSizeSoFar( )
--   Get the amount of bytes outputted so far.
--   Raises an error if no file or string is being processed.
function metaFuncs.getOutputSizeSoFar()
	errorIfNotRunningMeta(2)

	local size = 0

	for _, lua in ipairs(current_meta_outputStack[1]) do -- :GetMoreOutputFromStack
		size = size + #lua
	end

	return size
end

-- getCurrentLineNumberInOutput()
--   lineNumber = getCurrentLineNumberInOutput( )
--   Get the current line number in the output.
function metaFuncs.getCurrentLineNumberInOutput()
	errorIfNotRunningMeta(2)

	local ln = 1

	for _, lua in ipairs(current_meta_outputStack[1]) do -- :GetMoreOutputFromStack
		ln = ln + countString(lua, "\n", true)
	end

	return ln
end

local function getIndentation(line, tabWidth)
	if not tabWidth then
		return line:match"^[ \t]*"
	end

	local indent = 0

	for i = 1, #line do
		if line:sub(i, i) == "\t" then
			indent = math.floor(indent/tabWidth)*tabWidth + tabWidth
		elseif line:sub(i, i) == " " then
			indent = indent + 1
		else
			break
		end
	end

	return indent
end

-- getIndentation()
--   string = getIndentation( line )
--   size   = getIndentation( line, tabWidth )
--   Get indentation of a line, either as a string or as a size in spaces.
metaFuncs.getIndentation = getIndentation

-- getCurrentIndentationInOutput()
--   string = getCurrentIndentationInOutput( )
--   size   = getCurrentIndentationInOutput( tabWidth )
--   Get the indentation of the current line, either as a string or as a size in spaces.
function metaFuncs.getCurrentIndentationInOutput(tabWidth)
	errorIfNotRunningMeta(2)
	return (getIndentation(getOutputSoFarOnLine(), tabWidth))
end

-- getCurrentPathIn()
--   path = getCurrentPathIn( )
--   Get what file is currently being processed, if any.
function metaFuncs.getCurrentPathIn()
	return current_anytime_pathIn
end

-- getCurrentPathOut()
--   path = getCurrentPathOut( )
--   Get what file the currently processed file will be written to, if any.
function metaFuncs.getCurrentPathOut()
	return current_anytime_pathOut
end

-- tokenize()
--   tokens = tokenize( luaString [, allowPreprocessorCode=false ] )
--   token = {
--     type=tokenType, representation=representation, value=value,
--     line=lineNumber, lineEnd=lineNumber, position=bytePosition, file=filePath,
--     ...
--   }
--   Convert Lua code to tokens. Returns nil and a message on error. (See newToken() for token types.)
function metaFuncs.tokenize(lua, allowPpCode)
	local ok, errOrTokens = pcall(_tokenize, lua, "<string>", allowPpCode, allowPpCode, true) -- @Incomplete: Make allowJitSyntax a parameter to tokenize()?
	if not ok then
		return nil, cleanError(errOrTokens)
	end
	return errOrTokens
end

-- removeUselessTokens()
--   removeUselessTokens( tokens )
--   Remove whitespace and comment tokens.
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

	for i = len, len+offset+1, -1 do
		tokens[i] = nil
	end
end

local function nextUsefulToken(tokens, i)
	while true do
		i = i+1
		local tok = tokens[i]
		if not tok                      then  return         end
		if not USELESS_TOKENS[tok.type] then  return i, tok  end
	end
end

-- eachToken()
--   for index, token in eachToken( tokens [, ignoreUselessTokens=false ] ) do
--   Loop through tokens.
function metaFuncs.eachToken(tokens, ignoreUselessTokens)
	if ignoreUselessTokens then
		return nextUsefulToken, tokens, 0
	else
		return ipairs(tokens)
	end
end

-- getNextUsefulToken()
--   token, index = getNextUsefulToken( tokens, startIndex [, steps=1 ] )
--   Get the next token that isn't a whitespace or comment. Returns nil if no more tokens are found.
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

local numberFormatters = {
	auto        = function(n) return tostring(n) end,
	integer     = function(n) return F("%d", n) end,
	int         = function(n) return F("%d", n) end,
	float       = function(n) return F("%f", n):gsub("(%d)0+$", "%1") end,
	scientific  = function(n) return F("%e", n):gsub("(%d)0+e", "%1e"):gsub("0+(%d+)$", "%1") end,
	SCIENTIFIC  = function(n) return F("%E", n):gsub("(%d)0+E", "%1E"):gsub("0+(%d+)$", "%1") end,
	e           = function(n) return F("%e", n):gsub("(%d)0+e", "%1e"):gsub("0+(%d+)$", "%1") end,
	E           = function(n) return F("%E", n):gsub("(%d)0+E", "%1E"):gsub("0+(%d+)$", "%1") end,
	hexadecimal = function(n) return (n == math.floor(n) and F("0x%x", n) or error("Hexadecimal floats not supported yet.", 3)) end, -- @Incomplete
	HEXADECIMAL = function(n) return (n == math.floor(n) and F("0x%X", n) or error("Hexadecimal floats not supported yet.", 3)) end,
	hex         = function(n) return (n == math.floor(n) and F("0x%x", n) or error("Hexadecimal floats not supported yet.", 3)) end,
	HEX         = function(n) return (n == math.floor(n) and F("0x%X", n) or error("Hexadecimal floats not supported yet.", 3)) end,
}

-- newToken()
--   token = newToken( tokenType, ... )
--   Create a new token. Different token types take different arguments.
--
--   commentToken     = newToken( "comment",     contents [, forceLongForm=false ] )
--   identifierToken  = newToken( "identifier",  identifier )
--   keywordToken     = newToken( "keyword",     keyword )
--   numberToken      = newToken( "number",      number [, numberFormat="auto" ] )
--   punctuationToken = newToken( "punctuation", symbol )
--   stringToken      = newToken( "string",      contents [, longForm=false ] )
--   whitespaceToken  = newToken( "whitespace",  contents )
--   ppEntryToken     = newToken( "pp_entry",    isDouble )
--   ppKeywordToken   = newToken( "pp_keyword",  ppKeyword ) -- ppKeyword can be "file", "insert", "line" or "@".
--   ppSymbolToken    = newToken( "pp_symbol",   identifier )
--
--   commentToken     = { type="comment",     representation=string, value=string, long=isLongForm }
--   identifierToken  = { type="identifier",  representation=string, value=string }
--   keywordToken     = { type="keyword",     representation=string, value=string }
--   numberToken      = { type="number",      representation=string, value=number }
--   punctuationToken = { type="punctuation", representation=string, value=string }
--   stringToken      = { type="string",      representation=string, value=string, long=isLongForm }
--   whitespaceToken  = { type="whitespace",  representation=string, value=string }
--   ppEntryToken     = { type="pp_entry",    representation=string, value=string, double=isDouble }
--   ppKeywordToken   = { type="pp_keyword",  representation=string, value=string }
--   ppSymbolToken    = { type="pp_symbol",   representation=string, value=string }
--
-- Number formats:
--   "integer"      E.g. 42
--   "int"          Same as integer, e.g. 42
--   "float"        E.g. 3.14
--   "scientific"   E.g. 0.7e+12
--   "SCIENTIFIC"   E.g. 0.7E+12 (upper case)
--   "e"            Same as scientific, e.g. 0.7e+12
--   "E"            Same as SCIENTIFIC, e.g. 0.7E+12 (upper case)
--   "hexadecimal"  E.g. 0x19af
--   "HEXADECIMAL"  E.g. 0x19AF (upper case)
--   "hex"          Same as hexadecimal, e.g. 0x19af
--   "HEX"          Same as HEXADECIMAL, e.g. 0x19AF (upper case)
--   "auto"         Note: Infinite numbers and NaN always get automatic format.
--
function metaFuncs.newToken(tokType, ...)
	if tokType == "comment" then
		local comment, long = ...
		long                = not not (long or comment:find"[\r\n]")
		assertarg(2, comment, "string")

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
		assertarg(2, ident, "string")

		if ident == "" then
			error("Identifier length is 0.", 2)
		elseif not ident:find"^[%a_][%w_]*$" then
			errorf(2, "Bad identifier format: '%s'", ident)
		elseif KEYWORDS[ident] then
			errorf(2, "Identifier must not be a keyword: '%s'", ident)
		end

		return {type="identifier", representation=ident, value=ident}

	elseif tokType == "keyword" then
		local keyword = ...
		assertarg(2, keyword, "string")

		if not KEYWORDS[keyword] then
			errorf(2, "Bad keyword '%s'.", keyword)
		end

		return {type="keyword", representation=keyword, value=keyword}

	elseif tokType == "number" then
		local n, numberFormat = ...
		numberFormat          = numberFormat or "auto"
		assertarg(2, n,            "number")
		assertarg(3, numberFormat, "string")

		-- Some of these are technically multiple other tokens. We could raise an error but ehhh...
		local numStr = (
			n ~=  n   and "(0/0)"  or
			n ==  1/0 and "(1/0)"  or
			n == -1/0 and "(-1/0)" or
			numberFormatters[numberFormat] and numberFormatters[numberFormat](n) or
			errorf(2, "Invalid number format '%s'.", numberFormat)
		)

		return {type="number", representation=numStr, value=n}

	elseif tokType == "punctuation" then
		local symbol = ...
		assertarg(2, symbol, "string")

		-- Note: "!" and "!!" are of a different token type (pp_entry).
		if not PUNCTUATION[symbol] then
			errorf(2, "Bad symbol '%s'.", symbol)
		end

		return {type="punctuation", representation=symbol, value=symbol}

	elseif tokType == "string" then
		local s, long = ...
		long          = not not long
		assertarg(2, s, "string")

		local repr

		if long then
			local equalSigns = ""

			while s:find(F("]%s]", equalSigns), 1, true) do
				equalSigns = equalSigns .. "="
			end

			repr = F("[%s[%s]%s]", equalSigns, s, equalSigns)

		else
			repr = toLua(s)
		end

		return {type="string", representation=repr, value=s, long=long}

	elseif tokType == "whitespace" then
		local whitespace = ...
		assertarg(2, whitespace, "string")

		if whitespace == "" then
			error("String is empty.", 2)
		elseif whitespace:find"%S" then
			error("String contains non-whitespace characters.", 2)
		end

		return {type="whitespace", representation=whitespace, value=whitespace}

	elseif tokType == "pp_entry" then
		local double = ...
		assertarg(2, double, "boolean")

		local symbol = double and "!!" or "!"

		return {type="pp_entry", representation=symbol, value=symbol, double=double}

	elseif tokType == "pp_keyword" then
		local keyword = ...
		assertarg(2, keyword, "string")

		if keyword == "@" then
			return {type="pp_keyword", representation="@@", value="insert"}
		elseif not PREPROCESSOR_KEYWORDS[keyword] then
			errorf(2, "Bad preprocessor keyword '%s'.", keyword)
		else
			return {type="pp_keyword", representation="@"..keyword, value=keyword}
		end

	elseif tokType == "pp_symbol" then
		local ident = ...
		assertarg(2, ident, "string")

		if ident == "" then
			error("Identifier length is 0.", 2)
		elseif not ident:find"^[%a_][%w_]*$" then
			errorf(2, "Bad identifier format: '%s'", ident)
		elseif KEYWORDS[ident] then
			errorf(2, "Identifier must not be a keyword: '%s'", ident)
		else
			return {type="pp_symbol", representation="$"..ident, value=ident}
		end

	else
		errorf(2, "Invalid token type '%s'.", tostring(tokType))
	end
end

-- concatTokens()
--   luaString = concatTokens( tokens )
--   Concatenate tokens by their representations.
function metaFuncs.concatTokens(tokens)
	return (_concatTokens(tokens, nil, false, nil, nil))
end

local recycledArrays = {}

-- startInterceptingOutput()
--   startInterceptingOutput( )
--   Start intercepting output until stopInterceptingOutput() is called.
--   The function can be called multiple times to intercept interceptions.
function metaFuncs.startInterceptingOutput()
	errorIfNotRunningMeta(2)

	current_meta_output = tableRemove(recycledArrays) or {}
	for i = 1, #current_meta_output do  current_meta_output[i] = nil  end
	tableInsert(current_meta_outputStack, current_meta_output)
end

local function _stopInterceptingOutput(errLevel)
	errorIfNotRunningMeta(1+errLevel)

	local interceptedLua = tableRemove(current_meta_outputStack)
	current_meta_output  = current_meta_outputStack[#current_meta_outputStack] or error("Called stopInterceptingOutput() before calling startInterceptingOutput().", 1+errLevel)
	tableInsert(recycledArrays, interceptedLua)

	return table.concat(interceptedLua)
end

-- stopInterceptingOutput()
--   luaString = stopInterceptingOutput( )
--   Stop intercepting output and retrieve collected code.
function metaFuncs.stopInterceptingOutput()
	return (_stopInterceptingOutput(2))
end

-- loadResource()
--   luaString = loadResource( name )
--   Load a Lua file/resource (using the same mechanism as @insert"name").
--   Note that resources are cached after loading once.
function metaFuncs.loadResource(resourceName)
	errorIfNotRunningMeta(2)

	return (_loadResource(resourceName, false, 2))
end

local function isCallable(v)
	return type(v) == "function"
		-- We use debug.getmetatable instead of _G.getmetatable because we don't want to
		-- potentially invoke user code - we just want to know if the value is callable.
		or (type(v) == "table" and debug.getmetatable(v) ~= nil and type(debug.getmetatable(v).__call) == "function")
end

-- callMacro()
--   luaString = callMacro( function|macroName, argument1, ... )
--   Call a macro function (which must be a global in metaEnvironment if macroName is given).
--   The arguments should be Lua code strings.
function metaFuncs.callMacro(nameOrFunc, ...)
	errorIfNotRunningMeta(2)

	assertarg(1, nameOrFunc, "string","function")
	local f

	if type(nameOrFunc) == "string" then
		local nameResult = current_parsingAndMeta_macroPrefix .. nameOrFunc .. current_parsingAndMeta_macroSuffix
		f                = metaEnv[nameResult]

		if not isCallable(f) then
			if    nameOrFunc == nameResult
			then  errorf(2, "'%s' is not a macro/global function. (Got %s)", nameOrFunc, type(f))
			else  errorf(2, "'%s' (resolving to '%s') is not a macro/global function. (Got %s)", nameOrFunc, nameResult, type(f))  end
		end

	else
		f = nameOrFunc
	end

	return (metaEnv.__M()(f(...)))
end

-- isProcessing()
--   bool = isProcessing( )
--   Returns true if a file or string is currently being processed.
function metaFuncs.isProcessing()
	return current_parsingAndMeta_isProcessing
end

-- :PredefinedMacros

-- ASSERT()
--   @@ASSERT( condition [, message=auto ] )
--   Macro. Does nothing if params.release is set, otherwise calls error() if the
--   condition fails. The message argument is only evaluated if the condition fails.
function metaFuncs.ASSERT(conditionCode, messageCode)
	errorIfNotRunningMeta(2)
	if not conditionCode then  error("missing argument #1 to 'ASSERT'", 2)  end

	-- if not isLuaStringValidExpression(conditionCode) then
	-- 	errorf(2, "Invalid condition expression: %s", formatCodeForShortMessage(conditionCode))
	-- end

	if current_meta_releaseMode then  return  end

	tableInsert(current_meta_output, "if not (")
	tableInsert(current_meta_output, conditionCode)
	tableInsert(current_meta_output, ") then  error(")

	if messageCode then
		tableInsert(current_meta_output, "(")
		tableInsert(current_meta_output, messageCode)
		tableInsert(current_meta_output, ")")
	else
		tableInsert(current_meta_output, F("%q", "Assertion failed: "..conditionCode))
	end

	tableInsert(current_meta_output, ")  end")
end

-- LOG()
--   @@LOG( logLevel, value )               -- [1]
--   @@LOG( logLevel, format, value1, ... ) -- [2]
--
--   Macro. Does nothing if logLevel is lower than params.logLevel,
--   otherwise prints a value[1] or a formatted message[2].
--
--   logLevel can be "error", "warning", "info", "debug" or "trace"
--   (from highest to lowest priority).
--
function metaFuncs.LOG(logLevelCode, valueOrFormatCode, ...)
	errorIfNotRunningMeta(2)
	if not logLevelCode      then  error("missing argument #1 to 'LOG'", 2)  end
	if not valueOrFormatCode then  error("missing argument #2 to 'LOG'", 2)  end

	local chunk = loadLuaString("return("..logLevelCode.."\n)", "@", dummyEnv)
	if not chunk then  errorf(2, "Invalid logLevel expression: %s", formatCodeForShortMessage(logLevelCode))  end

	local ok, logLevel = pcall(chunk)
	if not ok                   then  errorf(2, "logLevel must be a constant expression. Got: %s", formatCodeForShortMessage(logLevelCode))  end
	if not LOG_LEVELS[logLevel] then  errorf(2, "Invalid logLevel '%s'.", tostring(logLevel))  end
	if logLevel == "off"        then  errorf(2, "Invalid logLevel '%s'.", tostring(logLevel))  end

	if LOG_LEVELS[logLevel] > LOG_LEVELS[current_meta_maxLogLevel] then  return  end

	tableInsert(current_meta_output, "print(")

	if ... then
		tableInsert(current_meta_output, "string.format(")
		tableInsert(current_meta_output, valueOrFormatCode)
		for i = 1, select("#", ...) do
			tableInsert(current_meta_output, ", ")
			tableInsert(current_meta_output, (select(i, ...)))
		end
		tableInsert(current_meta_output, ")")
	else
		tableInsert(current_meta_output, valueOrFormatCode)
	end

	tableInsert(current_meta_output, ")")
end

-- Extra stuff used by the command line program:
metaFuncs.tryToFormatError = tryToFormatError

----------------------------------------------------------------



for k, v in pairs(metaFuncs) do  metaEnv[k] = v  end

metaEnv.__LUA = metaEnv.outputLua
metaEnv.__VAL = metaEnv.outputValue

function metaEnv.__TOLUA(v)
	return (assert(toLua(v)))
end
function metaEnv.__ISLUA(lua)
	if type(lua) ~= "string" then
		error("Value is not Lua code.", 2)
	end
	return lua
end

local function finalizeMacro(lua)
	if lua == nil then
		return (_stopInterceptingOutput(2))
	elseif type(lua) ~= "string" then
		errorf(2, "[Macro] Value is not Lua code. (Got %s)", type(lua))
	elseif current_meta_output[1] then
		error("[Macro] Got Lua code from both value expression and outputLua(). Only one method may be used.", 2) -- It's also possible interception calls are unbalanced.
	else
		_stopInterceptingOutput(2) -- Returns "" because nothing was outputted.
		return lua
	end
end
function metaEnv.__M()
	metaFuncs.startInterceptingOutput()
	return finalizeMacro
end

-- luaString = __ARG( locationTokenNumber, luaString|callback )
-- callback  = function( )
function metaEnv.__ARG(locTokNum, v)
	local lua
	if type(v) == "string" then
		lua = v
	else
		metaFuncs.startInterceptingOutput()
		v()
		lua = _stopInterceptingOutput(2)
	end

	if current_parsingAndMeta_strictMacroArguments and not isLuaStringValidExpression(lua) then
		runtimeErrorAtToken(2, current_meta_locationTokens[locTokNum], nil, "MacroArgument", "Argument result is not a valid Lua expression: %s", formatCodeForShortMessage(lua))
	end

	return lua
end

function metaEnv.__EVAL(v) -- For symbols.
	if isCallable(v) then
		v = v()
	end
	return v
end



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



--
-- Preprocessor expansions (symbols etc., not macros).
--

local function newTokenAt(tok, locTok)
	tok.line     = tok.line     or locTok and locTok.line
	tok.lineEnd  = tok.lineEnd  or locTok and locTok.lineEnd
	tok.position = tok.position or locTok and locTok.position
	tok.file     = tok.file     or locTok and locTok.file
	return tok
end

local function popTokens(tokenStack, lastIndexToPop)
	for i = #tokenStack, lastIndexToPop, -1 do
		tokenStack[i] = nil
	end
end
local function popUseless(tokenStack)
	for i = #tokenStack, 1, -1 do
		if not USELESS_TOKENS[tokenStack[i].type] then  break  end
		tokenStack[i] = nil
	end
end

local function advanceToken(tokens)
	local tok    = tokens[tokens.nextI]
	tokens.nextI = tokens.nextI + 1
	return tok
end
local function advancePastUseless(tokens)
	for i = tokens.nextI, #tokens do
		if not USELESS_TOKENS[tokens[i].type] then  break  end
		tokens.nextI = i + 1
	end
end

-- outTokens = doEarlyExpansions( tokensToExpand, stats )
local function doEarlyExpansions(tokensToExpand, stats)
	--
	-- Here we expand simple things that makes it easier for
	-- doLateExpansions*() to do more elaborate expansions.
	--
	-- Expand expressions:
	--   @file
	--   @line
	--   ` ... `
	--   $symbol
	--
	local tokenStack = {} -- We process the last token first, and we may push new tokens onto the stack.
	local outTokens  = {}

	for i = #tokensToExpand, 1, -1 do
		tableInsert(tokenStack, tokensToExpand[i])
	end

	while tokenStack[1] do
		local tok = tokenStack[#tokenStack]

		-- Keyword.
		if isToken(tok, "pp_keyword") then
			local ppKeywordTok = tok

			-- @file
			-- @line
			if ppKeywordTok.value == "file" then
				tableRemove(tokenStack) -- '@file'
				tableInsert(outTokens, newTokenAt({type="string", value=ppKeywordTok.file, representation=F("%q",ppKeywordTok.file)}, ppKeywordTok))
			elseif ppKeywordTok.value == "line" then
				tableRemove(tokenStack) -- '@line'
				tableInsert(outTokens, newTokenAt({type="number", value=ppKeywordTok.line, representation=F(" %d ",ppKeywordTok.line)}, ppKeywordTok)) -- Is it fine for the representation to have spaces? Probably.

			else
				-- Expand later.
				tableInsert(outTokens, ppKeywordTok)
				tableRemove(tokenStack) -- '@...'
			end

		-- Backtick string.
		elseif isToken(tok, "string") and tok.representation:find"^`" then
			local stringTok          = tok
			stringTok.representation = toLua(stringTok.value)--F("%q", stringTok.value)

			tableInsert(outTokens, stringTok)
			tableRemove(tokenStack) -- the string

		-- Symbol. (Should this expand later? Does it matter? Yeah, do this in the AST code instead. @Cleanup)
		elseif isToken(tok, "pp_symbol") then
			local ppSymbolTok = tok

			-- $symbol
			tableRemove(tokenStack) -- '$symbol'
			tableInsert(outTokens, newTokenAt({type="pp_entry",    value="!!",              representation="!!", double=true}, ppSymbolTok))
			tableInsert(outTokens, newTokenAt({type="punctuation", value="(",               representation="("              }, ppSymbolTok))
			tableInsert(outTokens, newTokenAt({type="identifier",  value="__EVAL",          representation="__EVAL"         }, ppSymbolTok))
			tableInsert(outTokens, newTokenAt({type="punctuation", value="(",               representation="("              }, ppSymbolTok))
			tableInsert(outTokens, newTokenAt({type="identifier",  value=ppSymbolTok.value, representation=ppSymbolTok.value}, ppSymbolTok))
			tableInsert(outTokens, newTokenAt({type="punctuation", value=")",               representation=")"              }, ppSymbolTok))
			tableInsert(outTokens, newTokenAt({type="punctuation", value=")",               representation=")"              }, ppSymbolTok))

		-- Anything else.
		else
			tableInsert(outTokens, tok)
			tableRemove(tokenStack) -- anything
		end
	end--while tokenStack

	return outTokens
end

-- outTokens = doLateExpansions( tokensToExpand, stats, allowBacktickStrings, allowJitSyntax )
local function doLateExpansions(tokensToExpand, stats, allowBacktickStrings, allowJitSyntax)
	--
	-- Expand expressions:
	--   @insert "name"
	--
	local tokenStack = {} -- We process the last token first, and we may push new tokens onto the stack.
	local outTokens  = {}

	for i = #tokensToExpand, 1, -1 do
		tableInsert(tokenStack, tokensToExpand[i])
	end

	while tokenStack[1] do
		local tok = tokenStack[#tokenStack]

		-- Keyword.
		if isToken(tok, "pp_keyword") then
			local ppKeywordTok   = tok
			local tokNext, iNext = getNextUsableToken(tokenStack, #tokenStack-1, nil, -1)

			-- @insert "name"
			if ppKeywordTok.value == "insert" and isTokenAndNotNil(tokNext, "string") and tokNext.file == ppKeywordTok.file then
				local nameTok = tokNext
				popTokens(tokenStack, iNext) -- the string

				local toInsertName   = nameTok.value
				local toInsertLua    = _loadResource(toInsertName, true, nameTok, stats)
				local toInsertTokens = _tokenize(toInsertLua, toInsertName, true, allowBacktickStrings, allowJitSyntax)
				toInsertTokens       = doEarlyExpansions(toInsertTokens, stats)

				for i = #toInsertTokens, 1, -1 do
					tableInsert(tokenStack, toInsertTokens[i])
				end

				local lastTok            = toInsertTokens[#toInsertTokens]
				stats.processedByteCount = stats.processedByteCount + #toInsertLua
				stats.lineCount          = stats.lineCount          + (lastTok and lastTok.line + countString(lastTok.representation, "\n", true) or 0)
				stats.lineCountCode      = stats.lineCountCode      + getLineCountWithCode(toInsertTokens)

			-- @insert identifier ( argument1, ... )
			-- @insert identifier " ... "
			-- @insert identifier { ... }
			-- @insert identifier !( ... )
			-- @insert identifier !!( ... )
			elseif ppKeywordTok.value == "insert" and isTokenAndNotNil(tokNext, "identifier") and tokNext.file == ppKeywordTok.file then
				local identTok = tokNext
				tokNext, iNext = getNextUsableToken(tokenStack, iNext-1, nil, -1)

				if not (tokNext and (
					tokNext.type == "string"
					or (tokNext.type == "punctuation" and isAny(tokNext.value, "(","{",".",":","["))
					or tokNext.type == "pp_entry"
				)) then
					errorAtToken(identTok, identTok.position+#identTok.representation, "Parser/Macro", "Expected '(' after macro name '%s'.", identTok.value)
				end

				-- Expand later.
				tableInsert(outTokens, tok)
				tableRemove(tokenStack) -- '@insert'

			elseif ppKeywordTok.value == "insert" then
				errorAtToken(
					ppKeywordTok, (tokNext and tokNext.position or ppKeywordTok.position+#ppKeywordTok.representation),
					"Parser", "Expected a string or identifier after %s.", ppKeywordTok.representation
				)

			else
				errorAtToken(ppKeywordTok, nil, "Parser", "Internal error. (%s)", ppKeywordTok.value)
			end

		-- Anything else.
		else
			tableInsert(outTokens, tok)
			tableRemove(tokenStack) -- anything
		end
	end--while tokenStack

	return outTokens
end

-- outTokens = doExpansions( params, tokensToExpand, stats )
local function doExpansions(params, tokens, stats)
	tokens = doEarlyExpansions(tokens, stats)
	tokens = doLateExpansions (tokens, stats, params.backtickStrings, params.jitSyntax) -- Resources.
	return tokens
end



--
-- Metaprogram generation.
--

local function AstSequence(locTok, tokens) return {
	type          = "sequence",
	locationToken = locTok,
	nodes         = tokens or {},
} end
local function AstLua(locTok, tokens) return { -- plain Lua
	type          = "lua",
	locationToken = locTok,
	tokens        = tokens or {},
} end
local function AstMetaprogram(locTok, tokens) return { -- `!(statements)` or `!statements`
	type          = "metaprogram",
	locationToken = locTok,
	originIsLine  = false,
	tokens        = tokens or {},
} end
local function AstExpressionCode(locTok, tokens) return { -- `!!(expression)`
	type          = "expressionCode",
	locationToken = locTok,
	tokens        = tokens or {},
} end
local function AstExpressionValue(locTok, tokens) return { -- `!(expression)`
	type          = "expressionValue",
	locationToken = locTok,
	tokens        = tokens or {},
} end
local function AstDualCode(locTok, valueTokens) return { -- `!!declaration` or `!!assignment`
	type          = "dualCode",
	locationToken = locTok,
	isDeclaration = false,
	names         = {},
	valueTokens   = valueTokens or {},
} end
-- local function AstSymbol(locTok) return { -- `$name`
-- 	type          = "symbol",
-- 	locationToken = locTok,
-- 	name          = "",
-- } end
local function AstMacro(locTok, calleeTokens) return { -- `@@callee(arguments)` or `@@callee{}` or `@@callee""`
	type          = "macro",
	locationToken = locTok,
	calleeTokens  = calleeTokens or {},
	arguments     = {}, -- []MacroArgument
} end
local function MacroArgument(locTok, nodes) return {
	locationToken = locTok,
	isComplex     = false,
	nodes         = nodes or {},
} end

local astParseMetaBlockOrLine

local function astParseMetaBlock(tokens)
	local ppEntryTokIndex = tokens.nextI
	local ppEntryTok      = tokens[ppEntryTokIndex]
	tokens.nextI          = tokens.nextI + 2 -- '!(' or '!!('

	local outTokens  = {}
	local depthStack = {}

	while true do
		local tok = tokens[tokens.nextI]

		if not tok then
			if depthStack[1] then
				tok = depthStack[#depthStack].startToken
				errorAtToken(tok, nil, "Parser/MetaBlock", "Could not find matching bracket before EOF. (Preprocessor line starts %s)", getRelativeLocationText(ppEntryTok, tok))
			end
			break
		end

		-- End of meta block.
		if not depthStack[1] and isToken(tok, "punctuation", ")") then
			tokens.nextI = tokens.nextI + 1 -- after ')'
			break

		-- Nested metaprogram (not supported).
		elseif tok.type:find"^pp_" then
			errorAtToken(tok, nil, "Parser/MetaBlock", "Preprocessor token inside metaprogram (starting %s).", getRelativeLocationText(ppEntryTok, tok))

		-- Continuation of meta block.
		else
			if isToken(tok, "punctuation", "(") then
				tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]")"})
			elseif isToken(tok, "punctuation", "[") then
				tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]"]"})
			elseif isToken(tok, "punctuation", "{") then
				tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]"}"})

			elseif
				isToken(tok, "punctuation", ")") or
				isToken(tok, "punctuation", "]") or
				isToken(tok, "punctuation", "}")
			then
				if not depthStack[1] then
					errorAtToken(tok, nil, "Parser/MetaBlock", "Unexpected '%s'. (Preprocessor line starts %s)", tok.value, getRelativeLocationText(ppEntryTok, tok))
				elseif not isToken(tok, unpack(depthStack[#depthStack])) then
					local startTok = depthStack[#depthStack].startToken
					errorAtToken(
						tok, nil, "Parser/MetaBlock", "Expected '%s' (to close '%s' %s) but got '%s'. (Preprocessor line starts %s)",
						depthStack[#depthStack][2], startTok.value, getRelativeLocationText(startTok, tok), tok.value, getRelativeLocationText(ppEntryTok, tok)
					)
				end
				tableRemove(depthStack)
			end

			tableInsert(outTokens, tok)
			tokens.nextI = tokens.nextI + 1 -- after anything
		end
	end

	local lua          = _concatTokens(outTokens, nil, false, nil, nil)
	local chunk, err   = loadLuaString("return 0,"..lua.."\n,0", "@", nil)
	local isExpression = (chunk ~= nil)

	if not isExpression and ppEntryTok.double then
		errorAtToken(tokens[ppEntryTokIndex+1], nil, "Parser/MetaBlock", "Invalid expression in preprocessor block.")
		-- err = err:gsub("^:%d+: ", "")
		-- errorAtToken(tokens[ppEntryTokIndex+1], nil, "Parser/MetaBlock", "Invalid expression in preprocessor block. (%s)", err)
	elseif isExpression and not isLuaStringValidExpression(lua) then
		if #lua > 100 then
			lua = lua:sub(1, 50) .. "..." .. lua:sub(-50)
		end
		errorAtToken(tokens[ppEntryTokIndex+1], nil, "Parser/MetaBlock", "Ambiguous expression '%s'. (Comma-separated list?)", formatCodeForShortMessage(lua))
	end

	local astOutNode = ((ppEntryTok.double and AstExpressionCode) or (isExpression and AstExpressionValue or AstMetaprogram))(ppEntryTok, outTokens)
	return astOutNode
end

local function astParseMetaLine(tokens)
	local ppEntryTok = tokens[tokens.nextI]
	tokens.nextI     = tokens.nextI + 1 -- '!' or '!!'

	local isDual     = ppEntryTok.double
	local astOutNode = (isDual and AstDualCode or AstMetaprogram)(ppEntryTok)

	if astOutNode.type == "metaprogram" then
		astOutNode.originIsLine = true
	end

	if isDual then
		-- We expect the statement to look like any of these:
		-- !!local x, y = ...
		-- !!x, y = ...
		local tokNext, iNext = getNextUsableToken(tokens, tokens.nextI, nil, 1)

		if isTokenAndNotNil(tokNext, "keyword", "local") then
			astOutNode.isDeclaration = true

			tokens.nextI   = iNext + 1 -- after 'local'
			tokNext, iNext = getNextUsableToken(tokens, tokens.nextI, nil, 1)
		end

		local usedNames = {}

		while true do
			if not isTokenAndNotNil(tokNext, "identifier") then
				local tok = tokNext or tokens[#tokens]
				errorAtToken(
					tok, nil, "Parser/DualCodeLine", "Expected %sidentifier. (Preprocessor line starts %s)",
					(astOutNode.names[1] and "" or "'local' or "),
					getRelativeLocationText(ppEntryTok, tok)
				)
			elseif usedNames[tokNext.value] then
				errorAtToken(
					tokNext, nil, "Parser/DualCodeLine", "Duplicate name '%s' in %s. (Preprocessor line starts %s)",
					tokNext.value,
					(astOutNode.isDeclaration and "declaration" or "assignment"),
					getRelativeLocationText(ppEntryTok, tokNext)
				)
			end
			tableInsert(astOutNode.names, tokNext.value)
			usedNames[tokNext.value] = tokNext
			tokens.nextI             = iNext + 1 -- after the identifier
			tokNext, iNext           = getNextUsableToken(tokens, tokens.nextI, nil, 1)

			if not isTokenAndNotNil(tokNext, "punctuation", ",") then  break  end
			tokens.nextI   = iNext + 1 -- after ','
			tokNext, iNext = getNextUsableToken(tokens, tokens.nextI, nil, 1)
		end

		if not isTokenAndNotNil(tokNext, "punctuation", "=") then
			local tok = tokNext or tokens[#tokens]
			errorAtToken(
				tok, nil, "Parser/DualCodeLine", "Expected '=' in %s. (Preprocessor line starts %s)",
				(astOutNode.isDeclaration and "declaration" or "assignment"),
				getRelativeLocationText(ppEntryTok, tok)
			)
		end
		tokens.nextI = iNext + 1 -- after '='
	end

	-- Find end of metaprogram line.
	local outTokens  = isDual and astOutNode.valueTokens or astOutNode.tokens
	local depthStack = {}

	while true do
		local tok = tokens[tokens.nextI]

		if not tok then
			if depthStack[1] then
				tok = depthStack[#depthStack].startToken
				errorAtToken(tok, nil, "Parser/MetaLine", "Could not find matching bracket before EOF. (Preprocessor line starts %s)", getRelativeLocationText(ppEntryTok, tok))
			end
			break
		end

		-- End of meta line.
		if
			not depthStack[1] and (
				(tok.type == "whitespace" and tok.value:find("\n", 1, true)) or
				(tok.type == "comment"    and not tok.long)
			)
		then
			tableInsert(outTokens, tok)
			tokens.nextI = tokens.nextI + 1 -- after the whitespace or comment
			break

		-- Nested metaprogram (not supported).
		elseif tok.type:find"^pp_" then
			errorAtToken(tok, nil, "Parser/MetaLine", "Preprocessor token inside metaprogram (starting %s).", getRelativeLocationText(ppEntryTok, tok))

		-- Continuation of meta line.
		else
			if isToken(tok, "punctuation", "(") then
				tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]")"})
			elseif isToken(tok, "punctuation", "[") then
				tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]"]"})
			elseif isToken(tok, "punctuation", "{") then
				tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]"}"})

			elseif
				isToken(tok, "punctuation", ")") or
				isToken(tok, "punctuation", "]") or
				isToken(tok, "punctuation", "}")
			then
				if not depthStack[1] then
					errorAtToken(tok, nil, "Parser/MetaLine", "Unexpected '%s'. (Preprocessor line starts %s)", tok.value, getRelativeLocationText(ppEntryTok, tok))
				elseif not isToken(tok, unpack(depthStack[#depthStack])) then
					local startTok = depthStack[#depthStack].startToken
					errorAtToken(
						tok, nil, "Parser/MetaLine", "Expected '%s' (to close '%s' %s) but got '%s'. (Preprocessor line starts %s)",
						depthStack[#depthStack][2], startTok.value, getRelativeLocationText(startTok, tok), tok.value, getRelativeLocationText(ppEntryTok, tok)
					)
				end
				tableRemove(depthStack)
			end

			tableInsert(outTokens, tok)
			tokens.nextI = tokens.nextI + 1 -- after anything
		end
	end

	return astOutNode
end

--[[local]] function astParseMetaBlockOrLine(tokens)
	return isTokenAndNotNil(tokens[tokens.nextI+1], "punctuation", "(")
		and astParseMetaBlock(tokens)
		or  astParseMetaLine (tokens)
end

local function astParseMacro(params, tokens)
	local macroStartTok = tokens[tokens.nextI]
	tokens.nextI        = tokens.nextI + 1 -- after '@insert'

	local astMacro = AstMacro(macroStartTok)

	--
	-- Callee.
	--

	-- Add 'ident' for start of (or whole) callee.
	local tokNext, iNext = getNextUsableToken(tokens, tokens.nextI, nil, 1)
	if not isTokenAndNotNil(tokNext, "identifier") then
		printErrorTraceback("Internal error.")
		errorAtToken(tokNext, nil, "Parser/Macro", "Internal error. (%s)", (tokNext and tokNext.type or "?"))
	end
	tokens.nextI = iNext + 1 -- after the identifier
	tableInsert(astMacro.calleeTokens, tokNext)
	local initialCalleeIdentTok = tokNext

	-- Add macro prefix and suffix. (Note: We only edit the initial identifier in the callee if there are more.)
	initialCalleeIdentTok.value          = current_parsingAndMeta_macroPrefix .. initialCalleeIdentTok.value .. current_parsingAndMeta_macroSuffix
	initialCalleeIdentTok.representation = initialCalleeIdentTok.value

	-- Maybe add '.field[expr]:method' for rest of callee.
	tokNext, iNext = getNextUsableToken(tokens, tokens.nextI, nil, 1)

	while tokNext do
		if isToken(tokNext, "punctuation", ".") or isToken(tokNext, "punctuation", ":") then
			local punctTok = tokNext
			tokens.nextI   = iNext + 1 -- after '.' or ':'
			tableInsert(astMacro.calleeTokens, tokNext)

			tokNext, iNext = getNextUsableToken(tokens, tokens.nextI, nil, 1)
			if not tokNext then
				errorAfterToken(punctTok, "Parser/Macro", "Expected an identifier after '%s'.", punctTok.value)
			end
			tokens.nextI = iNext + 1 -- after the identifier
			tableInsert(astMacro.calleeTokens, tokNext)

			tokNext, iNext = getNextUsableToken(tokens, tokens.nextI, nil, 1)

			if punctTok.value == ":" then  break  end

		elseif isToken(tokNext, "punctuation", "[") then
			local punctTok = tokNext
			tokens.nextI   = iNext + 1 -- after '['
			tableInsert(astMacro.calleeTokens, tokNext)

			local bracketBalance = 1

			while true do
				tokNext = advanceToken(tokens) -- anything
				if not tokNext then
					errorAtToken(punctTok, nil, "Parser/Macro", "Could not find matching bracket before EOF. (Macro starts %s)", getRelativeLocationText(macroStartTok, punctTok))
				end
				tableInsert(astMacro.calleeTokens, tokNext)

				if isToken(tokNext, "punctuation", "[") then
					bracketBalance = bracketBalance + 1
				elseif isToken(tokNext, "punctuation", "]") then
					bracketBalance = bracketBalance - 1
					if bracketBalance == 0 then  break  end
				elseif tokNext.type:find"^pp_" then
					errorAtToken(tokNext, nil, "Parser/Macro", "Preprocessor token inside metaprogram/macro name expression (starting %s).", getRelativeLocationText(macroStartTok, tokNext))
				end
			end

			tokNext, iNext = getNextUsableToken(tokens, tokens.nextI, nil, 1)

			-- @UX: Validate that the contents form an expression.

		else
			break
		end
	end

	--
	-- Arguments.
	--

	-- @insert identifier " ... "
	if isTokenAndNotNil(tokNext, "string") then
		tableInsert(astMacro.arguments, MacroArgument(tokNext, {AstLua(tokNext, {tokNext})})) -- The one and only argument for this macro variant.
		tokens.nextI = iNext + 1 -- after the string

	-- @insert identifier { ... } -- Same as: @insert identifier ( { ... } )
	elseif isTokenAndNotNil(tokNext, "punctuation", "{") then
		local macroArg        = MacroArgument(tokNext) -- The one and only argument for this macro variant.
		astMacro.arguments[1] = macroArg

		local astLuaInCurrentArg = AstLua(tokNext, {tokNext})
		tableInsert(macroArg.nodes, astLuaInCurrentArg)

		tokens.nextI = iNext + 1 -- after '{'

		--
		-- (Similar code as `@insert identifier()` below.)
		--

		-- Collect tokens for the table arg.
		-- We're looking for the closing '}'.
		local bracketDepth = 1 -- @Incomplete: Track all brackets!

		while true do
			local tok = tokens[tokens.nextI]

			if not tok then
				errorAtToken(macroArg.locationToken, nil, "Parser/MacroArgument", "Could not find end of table constructor before EOF.")

			-- Preprocessor block in macro.
			elseif tok.type == "pp_entry" then
				tableInsert(macroArg.nodes, astParseMetaBlockOrLine(tokens))
				astLuaInCurrentArg = nil

			-- Nested macro.
			elseif isToken(tok, "pp_keyword", "insert") then
				tableInsert(macroArg.nodes, astParseMacro(params, tokens))
				astLuaInCurrentArg = nil

			-- Other preprocessor code in macro. (Not sure we ever get here.)
			elseif tok.type:find"^pp_" then
				errorAtToken(tok, nil, "Parser/MacroArgument", "Unsupported preprocessor code. (Macro starts %s)", getRelativeLocationText(macroStartTok, tok))

			-- End of table and argument.
			elseif bracketDepth == 1 and isToken(tok, "punctuation", "}") then
				if not astLuaInCurrentArg then
					astLuaInCurrentArg = AstLua(tok)
					tableInsert(macroArg.nodes, astLuaInCurrentArg)
				end
				tableInsert(astLuaInCurrentArg.tokens, tok)
				advanceToken(tokens) -- '}'
				break

			-- Normal token.
			else
				if isToken(tok, "punctuation", "{") then
					bracketDepth = bracketDepth + 1
				elseif isToken(tok, "punctuation", "}") then
					bracketDepth = bracketDepth - 1
				end

				if not astLuaInCurrentArg then
					astLuaInCurrentArg = AstLua(tok)
					tableInsert(macroArg.nodes, astLuaInCurrentArg)
				end
				tableInsert(astLuaInCurrentArg.tokens, tok)
				advanceToken(tokens) -- anything
			end
		end

	-- @insert identifier ( argument1, ... )
	elseif isTokenAndNotNil(tokNext, "punctuation", "(") then
		-- Apply the same 'ambiguous syntax' rule as Lua. (Will comments mess this check up? @Check)
		if isTokenAndNotNil(tokens[iNext-1], "whitespace") and tokens[iNext-1].value:find("\n", 1, true) then
			errorAtToken(tokNext, nil, "Parser/Macro", "Ambiguous syntax near '(' - part of macro, or new statement?")
		end

		local parensStartTok = tokNext
		tokens.nextI         = iNext + 1 -- after '('
		tokNext, iNext       = getNextUsableToken(tokens, tokens.nextI, nil, 1)

		if isTokenAndNotNil(tokNext, "punctuation", ")") then
			tokens.nextI = iNext + 1 -- after ')'

		else
			for argNum = 1, 1/0 do
				-- Collect tokens for this arg.
				-- We're looking for the next comma at depth 0 or closing ')'.
				local macroArg             = MacroArgument(tokens[tokens.nextI])
				astMacro.arguments[argNum] = macroArg

				advancePastUseless(tokens) -- Trim leading useless tokens.

				local astLuaInCurrentArg = nil
				local depthStack         = {}

				while true do
					local tok = tokens[tokens.nextI]

					if not tok then
						errorAtToken(parensStartTok, nil, "Parser/Macro", "Could not find end of argument list before EOF.")

					-- Preprocessor block in macro.
					elseif tok.type == "pp_entry" then
						tableInsert(macroArg.nodes, astParseMetaBlockOrLine(tokens))
						astLuaInCurrentArg = nil

					-- Nested macro.
					elseif isToken(tok, "pp_keyword", "insert") then
						tableInsert(macroArg.nodes, astParseMacro(params, tokens))
						astLuaInCurrentArg = nil

					-- Other preprocessor code in macro. (Not sure we ever get here.)
					elseif tok.type:find"^pp_" then
						errorAtToken(tok, nil, "Parser/MacroArgument", "Unsupported preprocessor code. (Macro starts %s)", getRelativeLocationText(macroStartTok, tok))

					-- End of argument.
					elseif not depthStack[1] and (isToken(tok, "punctuation", ",") or isToken(tok, "punctuation", ")")) then
						break

					-- Normal token.
					else
						if isToken(tok, "punctuation", "(") then
							tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]")"})
						elseif isToken(tok, "punctuation", "[") then
							tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]"]"})
						elseif isToken(tok, "punctuation", "{") then
							tableInsert(depthStack, {startToken=tok, --[[1]]"punctuation", --[[2]]"}"})
						elseif isToken(tok, "keyword", "function") or isToken(tok, "keyword", "if") or isToken(tok, "keyword", "do") then
							tableInsert(depthStack, {startToken=tok, --[[1]]"keyword", --[[2]]"end"})
						elseif isToken(tok, "keyword", "repeat") then
							tableInsert(depthStack, {startToken=tok, --[[1]]"keyword", --[[2]]"until"})

						elseif
							isToken(tok, "punctuation", ")")   or
							isToken(tok, "punctuation", "]")   or
							isToken(tok, "punctuation", "}")   or
							isToken(tok, "keyword",     "end") or
							isToken(tok, "keyword",     "until")
						then
							if not depthStack[1] then
								errorAtToken(tok, nil, "Parser/MacroArgument", "Unexpected '%s'.", tok.value)
							elseif not isToken(tok, unpack(depthStack[#depthStack])) then
								local startTok = depthStack[#depthStack].startToken
								errorAtToken(
									tok, nil, "Parser/MacroArgument", "Expected '%s' (to close '%s' %s) but got '%s'.",
									depthStack[#depthStack][2], startTok.value, getRelativeLocationText(startTok, tok), tok.value
								)
							end
							tableRemove(depthStack)
						end

						if not astLuaInCurrentArg then
							astLuaInCurrentArg = AstLua(tok)
							tableInsert(macroArg.nodes, astLuaInCurrentArg)
						end
						tableInsert(astLuaInCurrentArg.tokens, tok)
						advanceToken(tokens) -- anything
					end
				end

				if astLuaInCurrentArg then
					-- Trim trailing useless tokens.
					popUseless(astLuaInCurrentArg.tokens)
					if not astLuaInCurrentArg.tokens[1] then
						assert(tableRemove(macroArg.nodes) == astLuaInCurrentArg)
					end
				end

				if not macroArg.nodes[1] and current_parsingAndMeta_strictMacroArguments then
					-- There were no useful tokens for the argument!
					errorAtToken(macroArg.locationToken, nil, "Parser/MacroArgument", "Expected argument #%d.", argNum)
				end

				-- Do next argument or finish arguments.
				if isTokenAndNotNil(tokens[tokens.nextI], "punctuation", ")") then
					tokens.nextI = tokens.nextI + 1 -- after ')'
					break
				end

				assert(isToken(advanceToken(tokens), "punctuation", ",")) -- The loop above should have continued otherwise!
			end--for argNum
		end

	-- @insert identifier !( ... )  -- Same as: @insert identifier ( !( ... ) )
	-- @insert identifier !!( ... ) -- Same as: @insert identifier ( !!( ... ) )
	elseif isTokenAndNotNil(tokNext, "pp_entry") then
		tokens.nextI = iNext -- until '!' or '!!'

		if not isTokenAndNotNil(tokens[tokens.nextI+1], "punctuation", "(") then
			errorAfterToken(tokNext, "Parser/Macro", "Expected '(' after '%s'.", tokNext.value)
		end

		astMacro.arguments[1] = MacroArgument(tokNext, {astParseMetaBlock(tokens)}) -- The one and only argument for this macro variant.

	else
		errorAfterToken(astMacro.calleeTokens[#astMacro.calleeTokens], "Parser/Macro", "Expected '(' after macro name.")
	end

	return astMacro
end

local function astParse(params, tokens)
	-- @Robustness: Make sure everywhere that key tokens came from the same source file.
	local astSequence = AstSequence(tokens[1])
	tokens.nextI      = 1

	while true do
		local tok = tokens[tokens.nextI]
		if not tok then  break  end

		if isToken(tok, "pp_entry") then
			tableInsert(astSequence.nodes, astParseMetaBlockOrLine(tokens))

		elseif isToken(tok, "pp_keyword", "insert") then
			local astMacro = astParseMacro(params, tokens)
			tableInsert(astSequence.nodes, astMacro)

		-- elseif isToken(tok, "pp_symbol") then -- We currently expand these in doEarlyExpansions().
		-- 	errorAtToken(tok, nil, "Parser", "Internal error: @Incomplete: Handle symbols.")

		else
			local astLua = AstLua(tok)
			tableInsert(astSequence.nodes, astLua)

			while true do
				tableInsert(astLua.tokens, tok)
				advanceToken(tokens)

				tok = tokens[tokens.nextI]
				if not tok             then  break  end
				if tok.type:find"^pp_" then  break  end
			end
		end
	end

	return astSequence
end



-- lineNumber, lineNumberMeta = astNodeToMetaprogram( buffer, ast, lineNumber, lineNumberMeta, asMacroArgumentExpression )
local function astNodeToMetaprogram(buffer, ast, ln, lnMeta, asMacroArgExpr)
	if current_parsingAndMeta_addLineNumbers and not asMacroArgExpr then
		lnMeta = maybeOutputLineNumber(buffer, ast.locationToken, lnMeta)
	end

	--
	-- lua -> __LUA"lua"
	--
	if ast.type == "lua" then
		local lua = _concatTokens(ast.tokens, ln, current_parsingAndMeta_addLineNumbers, nil, nil)
		ln        = ast.tokens[#ast.tokens].line

		if not asMacroArgExpr then  tableInsert(buffer, "__LUA")  end

		if current_parsingAndMeta_isDebug then
			if not asMacroArgExpr then  tableInsert(buffer, "(")  end
			tableInsert(buffer, (F("%q", lua):gsub("\n", "n")))
			if not asMacroArgExpr then  tableInsert(buffer, ")\n")  end
		else
			tableInsert(buffer, F("%q", lua))
			if not asMacroArgExpr then  tableInsert(buffer, "\n")  end
		end

	--
	-- !(expression) -> __VAL(expression)
	--
	elseif ast.type == "expressionValue" then
		if    asMacroArgExpr
		then  tableInsert(buffer, "__TOLUA(")
		else  tableInsert(buffer, "__VAL((")  end

		for _, tok in ipairs(ast.tokens) do
			tableInsert(buffer, tok.representation)
		end

		if    asMacroArgExpr
		then  tableInsert(buffer, ")")
		else  tableInsert(buffer, "))\n")  end

	--
	-- !!(expression) -> __LUA(expression)
	--
	elseif ast.type == "expressionCode" then
		if    asMacroArgExpr
		then  tableInsert(buffer, "__ISLUA(")
		else  tableInsert(buffer, "__LUA((")  end

		for _, tok in ipairs(ast.tokens) do
			tableInsert(buffer, tok.representation)
		end

		if    asMacroArgExpr
		then  tableInsert(buffer, ")")
		else  tableInsert(buffer, "))\n")  end

	--
	-- !(statements) -> statements
	-- !statements   -> statements
	--
	elseif ast.type == "metaprogram" then
		if asMacroArgExpr then  internalError(ast.type)  end

		if ast.originIsLine then
			for i = 1, #ast.tokens-1 do
				tableInsert(buffer, ast.tokens[i].representation)
			end

			local lastTok = ast.tokens[#ast.tokens]
			if lastTok.type == "whitespace" then
				if current_parsingAndMeta_isDebug
				then  tableInsert(buffer, (F("\n__LUA(%q)\n", lastTok.value):gsub("\\\n", "\\n"))) -- Note: "\\\n" does not match "\n".
				else  tableInsert(buffer, (F("\n__LUA%q\n"  , lastTok.value):gsub("\\\n", "\\n")))  end
			else--if type == comment
				tableInsert(buffer, lastTok.representation)
				if current_parsingAndMeta_isDebug
				then  tableInsert(buffer, F('__LUA("\\n")\n'))
				else  tableInsert(buffer, F("__LUA'\\n'\n"  ))  end
			end

		else
			for _, tok in ipairs(ast.tokens) do
				tableInsert(buffer, tok.representation)
			end
			tableInsert(buffer, "\n")
		end

	--
	-- @@callee(argument1, ...) -> __LUA(__M(callee(__ARG(1,<argument1>), ...)))
	--                       OR -> __LUA(__M(callee(__ARG(1,function()<argument1>end), ...)))
	--
	-- The code handling each argument will be different depending on the complexity of the argument.
	--
	elseif ast.type == "macro" then
		if not asMacroArgExpr then  tableInsert(buffer, "__LUA(")  end

		tableInsert(buffer, "__M()(")
		for _, tok in ipairs(ast.calleeTokens) do
			tableInsert(buffer, tok.representation)
		end
		tableInsert(buffer, "(")

		for argNum, macroArg in ipairs(ast.arguments) do
			local argIsComplex = false -- If any part of the argument cannot be an expression then it's complex.

			for _, astInArg in ipairs(macroArg.nodes) do
				if astInArg.type == "metaprogram" or astInArg.type == "dualCode" then
					argIsComplex = true
					break
				end
			end

			if argNum > 1 then
				tableInsert(buffer, ",")
				if current_parsingAndMeta_isDebug then  tableInsert(buffer, " ")  end
			end

			local locTokNum                        = #current_meta_locationTokens + 1
			current_meta_locationTokens[locTokNum] = macroArg.nodes[1] and macroArg.nodes[1].locationToken or macroArg.locationToken or internalError()

			tableInsert(buffer, "__ARG(")
			tableInsert(buffer, tostring(locTokNum))
			tableInsert(buffer, ",")

			if argIsComplex then
				tableInsert(buffer, "function()\n")
				for nodeNumInArg, astInArg in ipairs(macroArg.nodes) do
					ln, lnMeta = astNodeToMetaprogram(buffer, astInArg, ln, lnMeta, false)
				end
				tableInsert(buffer, "end")

			elseif macroArg.nodes[1] then
				for nodeNumInArg, astInArg in ipairs(macroArg.nodes) do
					if nodeNumInArg > 1 then  tableInsert(buffer, "..")  end
					ln, lnMeta = astNodeToMetaprogram(buffer, astInArg, ln, lnMeta, true)
				end

			else
				tableInsert(buffer, '""')
			end

			tableInsert(buffer, ")")
		end

		tableInsert(buffer, "))")

		if not asMacroArgExpr then  tableInsert(buffer, ")\n")  end

	--
	-- !!local names = values -> local names = values ; __LUA"local names = "__VAL(name1)__LUA", "__VAL(name2)...
	-- !!      names = values ->       names = values ;       __LUA"names = "__VAL(name1)__LUA", "__VAL(name2)...
	--
	elseif ast.type == "dualCode" then
		if asMacroArgExpr then  internalError(ast.type)  end

		-- Metaprogram.
		if ast.isDeclaration then  tableInsert(buffer, "local ")  end
		tableInsert(buffer, table.concat(ast.names, ", "))
		tableInsert(buffer, ' = ')
		for _, tok in ipairs(ast.valueTokens) do
			tableInsert(buffer, tok.representation)
		end

		-- Final program.
		tableInsert(buffer, '__LUA')
		if current_parsingAndMeta_isDebug then  tableInsert(buffer, '(')  end
		tableInsert(buffer, '"') -- string start
		if current_parsingAndMeta_addLineNumbers then
			ln = maybeOutputLineNumber(buffer, ast.locationToken, ln)
		end
		if ast.isDeclaration then  tableInsert(buffer, "local ")  end
		tableInsert(buffer, table.concat(ast.names, ", "))
		tableInsert(buffer, ' = "') -- string end
		if current_parsingAndMeta_isDebug then  tableInsert(buffer, '); ')  end

		for i, name in ipairs(ast.names) do
			if     i == 1                         then  -- void
			elseif current_parsingAndMeta_isDebug then  tableInsert(buffer, '; __LUA(", "); ')
			else                                        tableInsert(buffer, '__LUA", "'      )  end
			tableInsert(buffer, "__VAL(")
			tableInsert(buffer, name)
			tableInsert(buffer, ")")
		end

		-- Use trailing semicolon if the user does.
		for i = #ast.valueTokens, 1, -1 do
			if isToken(ast.valueTokens[i], "punctuation", ";") then
				if    current_parsingAndMeta_isDebug
				then  tableInsert(buffer, '; __LUA(";")')
				else  tableInsert(buffer, '__LUA";"'    )  end
				break
			elseif not isToken(ast.valueTokens[i], "whitespace") then
				break
			end
		end

		if    current_parsingAndMeta_isDebug
		then  tableInsert(buffer, '; __LUA("\\n")\n')
		else  tableInsert(buffer, '__LUA"\\n"\n'    )  end

	--
	-- ...
	--
	elseif ast.type == "sequence" then
		for _, astChild in ipairs(ast.nodes) do
			ln, lnMeta = astNodeToMetaprogram(buffer, astChild, ln, lnMeta, false)
		end

	-- elseif ast.type == "symbol" then
	-- 	errorAtToken(ast.locationToken, nil, nil, "AstSymbol")

	else
		printErrorTraceback("Internal error.")
		errorAtToken(ast.locationToken, nil, "Parsing", "Internal error. (%s, %s)", ast.type, tostring(asMacroArgExpr))
	end

	return ln, lnMeta
end

local function astToLua(ast)
	local buffer = {}
	astNodeToMetaprogram(buffer, ast, 0, 0, false)
	return table.concat(buffer)
end



local function _processFileOrString(params, isFile)
	if isFile then
		if not params.pathIn  then  error("Missing 'pathIn' in params.",  2)  end
		if not params.pathOut then  error("Missing 'pathOut' in params.", 2)  end

		if params.pathOut == params.pathIn and params.pathOut ~= "-" then
			error("'pathIn' and 'pathOut' are the same in params.", 2)
		end

		if (params.pathMeta or "-") == "-" then -- Should it be possible to output the metaprogram to stdout?
			-- void
		elseif params.pathMeta == params.pathIn then
			error("'pathIn' and 'pathMeta' are the same in params.", 2)
		elseif params.pathMeta == params.pathOut then
			error("'pathOut' and 'pathMeta' are the same in params.", 2)
		end

	else
		if not params.code then  error("Missing 'code' in params.", 2)  end
	end

	-- Read input.
	local luaUnprocessed, virtualPathIn

	if isFile then
		virtualPathIn = params.pathIn
		local err

		if virtualPathIn == "-" then
			luaUnprocessed, err = io.stdin:read"*a"
		else
			luaUnprocessed, err = readFile(virtualPathIn, true)
		end

		if not luaUnprocessed then
			errorf("Could not read file '%s'. (%s)", virtualPathIn, err)
		end

		current_anytime_pathIn  = params.pathIn
		current_anytime_pathOut = params.pathOut

	else
		virtualPathIn  = "<code>"
		luaUnprocessed = params.code
	end

	current_anytime_fastStrings                 = params.fastStrings
	current_parsing_insertCount                 = 0
	current_parsingAndMeta_resourceCache        = {[virtualPathIn]=luaUnprocessed} -- The contents of files, unless params.onInsert() is specified in which case it's user defined.
	current_parsingAndMeta_onInsert             = params.onInsert
	current_parsingAndMeta_addLineNumbers       = params.addLineNumbers
	current_parsingAndMeta_macroPrefix          = params.macroPrefix or ""
	current_parsingAndMeta_macroSuffix          = params.macroSuffix or ""
	current_parsingAndMeta_strictMacroArguments = params.strictMacroArguments ~= false
	current_meta_locationTokens                 = {}

	local specialFirstLine, rest = luaUnprocessed:match"^(#[^\r\n]*\r?\n?)(.*)$"
	if specialFirstLine then
		specialFirstLine = specialFirstLine:gsub("\r", "") -- Normalize line breaks. (Assume the input is either "\n" or "\r\n".)
		luaUnprocessed   = rest
	end

	-- Ensure there's a newline at the end of the code, otherwise there will be problems down the line.
	if not (luaUnprocessed == "" or luaUnprocessed:find"\n%s*$") then
		luaUnprocessed = luaUnprocessed .. "\n"
	end

	local tokens = _tokenize(luaUnprocessed, virtualPathIn, true, params.backtickStrings, params.jitSyntax)
	-- printTokens(tokens) -- DEBUG

	-- Gather info.
	local lastTok = tokens[#tokens]

	local stats = {
		processedByteCount  = #luaUnprocessed,
		lineCount           = (specialFirstLine and 1 or 0) + (lastTok and lastTok.line + countString(lastTok.representation, "\n", true) or 0),
		lineCountCode       = getLineCountWithCode(tokens),
		tokenCount          = 0, -- Set later.
		hasPreprocessorCode = false,
		hasMetaprogram      = false,
		insertedNames       = {},
	}

	for _, tok in ipairs(tokens) do
		-- @Volatile: Make sure to update this when syntax is changed!
		if isToken(tok, "pp_entry") or isToken(tok, "pp_keyword", "insert") or isToken(tok, "pp_symbol") then
			stats.hasPreprocessorCode = true
			stats.hasMetaprogram      = true
			break
		elseif isToken(tok, "pp_keyword") or (isToken(tok, "string") and tok.representation:find"^`") then
			stats.hasPreprocessorCode = true
			-- Keep going as there may be metaprogram.
		end
	end

	-- Generate and run metaprogram.
	----------------------------------------------------------------

	local shouldProcess = stats.hasPreprocessorCode or params.addLineNumbers

	if shouldProcess then
		tokens = doExpansions(params, tokens, stats)
	end
	stats.tokenCount = #tokens

	current_meta_maxLogLevel = params.logLevel or "trace"
	if not LOG_LEVELS[current_meta_maxLogLevel] then
		errorf(2, "Invalid 'logLevel' value in params. (%s)", tostring(current_meta_maxLogLevel))
	end

	local lua

	if shouldProcess then
		local luaMeta = astToLua(astParse(params, tokens))
		--[[ DEBUG :PrintCode
		print("=META===============================")
		print(luaMeta)
		print("====================================")
		--]]

		-- Run metaprogram.
		current_meta_pathForErrorMessages = params.pathMeta or "<meta>"
		current_meta_output               = {}
		current_meta_outputStack          = {current_meta_output}
		current_meta_canOutputNil         = params.canOutputNil ~= false
		current_meta_releaseMode          = params.release

		if params.pathMeta then
			local file, err = io.open(params.pathMeta, "wb")
			if not file then  errorf("Count not open '%s' for writing. (%s)", params.pathMeta, err)  end

			file:write(luaMeta)
			file:close()
		end

		if params.onBeforeMeta then  params.onBeforeMeta(luaMeta)  end

		local main_chunk, err = loadLuaString(luaMeta, "@"..current_meta_pathForErrorMessages, metaEnv)
		if not main_chunk then
			local ln, _err = err:match"^.-:(%d+): (.*)"
			errorOnLine(current_meta_pathForErrorMessages, (tonumber(ln) or 0), nil, "%s", (_err or err))
		end

		current_anytime_isRunningMeta = true
		main_chunk() -- Note: Our caller should clean up current_meta_pathForErrorMessages etc. on error.
		current_anytime_isRunningMeta = false

		if not current_parsingAndMeta_isDebug and params.pathMeta then
			os.remove(params.pathMeta)
		end

		if current_meta_outputStack[2] then
			error("Called startInterceptingOutput() more times than stopInterceptingOutput().")
		end

		lua = table.concat(current_meta_output)
		--[[ DEBUG :PrintCode
		print("=OUTPUT=============================")
		print(lua)
		print("====================================")
		--]]

		current_meta_pathForErrorMessages = ""
		current_meta_output               = nil
		current_meta_outputStack          = nil
		current_meta_canOutputNil         = true
		current_meta_releaseMode          = false

	else
		-- @Copypaste from above.
		if not current_parsingAndMeta_isDebug and params.pathMeta then
			os.remove(params.pathMeta)
		end

		lua = luaUnprocessed
	end

	current_meta_maxLogLevel    = "trace"
	current_meta_locationTokens = nil

	if params.onAfterMeta then
		local luaModified = params.onAfterMeta(lua)

		if type(luaModified) == "string" then
			lua = luaModified
		elseif luaModified ~= nil then
			errorf("onAfterMeta() did not return a string. (Got %s)", type(luaModified))
		end
	end

	-- Write output file.
	----------------------------------------------------------------

	local pathOut = isFile and params.pathOut or "<output>"

	if isFile then
		if pathOut == "-" then
			io.stdout:write(specialFirstLine or "")
			io.stdout:write(lua)

		else
			local file, err = io.open(pathOut, "wb")
			if not file then  errorf("Count not open '%s' for writing. (%s)", pathOut, err)  end

			file:write(specialFirstLine or "")
			file:write(lua)
			file:close()
		end
	end

	-- Check if the output is valid Lua.
	if params.validate ~= false then
		local luaToCheck = lua:gsub("^#![^\n]*", "")
		local chunk, err = loadLuaString(luaToCheck, "@"..pathOut, nil)

		if not chunk then
			local ln, _err = err:match"^.-:(%d+): (.*)"
			errorOnLine(pathOut, (tonumber(ln) or 0), nil, "Output is invalid Lua. (%s)", (_err or err))
		end
	end

	-- :ProcessInfo
	local info = {
		path                = isFile and params.pathIn  or "",
		outputPath          = isFile and params.pathOut or "",
		processedByteCount  = stats.processedByteCount,
		lineCount           = stats.lineCount,
		linesOfCode         = stats.lineCountCode,
		tokenCount          = stats.tokenCount,
		hasPreprocessorCode = stats.hasPreprocessorCode,
		hasMetaprogram      = stats.hasMetaprogram,
		insertedFiles       = stats.insertedNames,
	}

	if params.onDone then  params.onDone(info)  end

	current_anytime_pathIn                      = ""
	current_anytime_pathOut                     = ""
	current_anytime_fastStrings                 = false
	current_parsingAndMeta_resourceCache        = nil
	current_parsingAndMeta_onInsert             = nil
	current_parsingAndMeta_addLineNumbers       = false
	current_parsingAndMeta_macroPrefix          = ""
	current_parsingAndMeta_macroSuffix          = ""
	current_parsingAndMeta_strictMacroArguments = true

	----------------------------------------------------------------

	if isFile then
		return info
	else
		if specialFirstLine then
			lua = specialFirstLine .. lua
		end
		return lua, info
	end
end

local function processFileOrString(params, isFile)
	if current_parsingAndMeta_isProcessing then
		error("Cannot process recursively.", 3) -- Note: We don't return failure in this case - it's a critical error!
	end

	-- local startTime = os.clock() -- :DebugMeasureTime  @Incomplete: Add processing time to returned info.
	local returnValues = nil

	current_parsingAndMeta_isProcessing = true
	current_parsingAndMeta_isDebug      = params.debug

	local xpcallOk, xpcallErr = xpcall(
		function()
			returnValues = pack(_processFileOrString(params, isFile))
		end,

		function(err)
			if type(err) == "string" and err:find("\0", 1, true) then
				printError(tryToFormatError(cleanError(err)))
			else
				printErrorTraceback(err, 2) -- The level should be at error().
			end

			if params.onError then
				local cbOk, cbErr = pcall(params.onError, err)
				if not cbOk then
					printfError("Additional error in params.onError()...\n%s", tryToFormatError(cbErr))
				end
			end

			return err
		end
	)

	current_parsingAndMeta_isProcessing = false
	current_parsingAndMeta_isDebug      = false

	-- Cleanup in case an error happened.
	current_anytime_isRunningMeta               = false
	current_anytime_pathIn                      = ""
	current_anytime_pathOut                     = ""
	current_anytime_fastStrings                 = false
	current_parsing_insertCount                 = 0
	current_parsingAndMeta_onInsert             = nil
	current_parsingAndMeta_resourceCache        = nil
	current_parsingAndMeta_addLineNumbers       = false
	current_parsingAndMeta_macroPrefix          = ""
	current_parsingAndMeta_macroSuffix          = ""
	current_parsingAndMeta_strictMacroArguments = true
	current_meta_pathForErrorMessages           = ""
	current_meta_output                         = nil
	current_meta_outputStack                    = nil
	current_meta_canOutputNil                   = true
	current_meta_releaseMode                    = false
	current_meta_maxLogLevel                    = "trace"
	current_meta_locationTokens                 = nil

	-- print("time", os.clock()-startTime) -- :DebugMeasureTime
	if xpcallOk then
		return unpack(returnValues, 1, returnValues.n)
	else
		return nil, cleanError(xpcallErr or "Unknown processing error.")
	end
end

local function processFile(params)
	local returnValues = pack(processFileOrString(params, true))
	return unpack(returnValues, 1, returnValues.n)
end

local function processString(params)
	local returnValues = pack(processFileOrString(params, false))
	return unpack(returnValues, 1, returnValues.n)
end



-- :ExportTable
local pp = {

	-- Processing functions.
	----------------------------------------------------------------

	-- processFile()
	-- Process a Lua file. Returns nil and a message on error.
	--
	-- info = processFile( params )
	-- info: Table with various information. (See 'ProcessInfo' for more info.)
	--
	-- params: Table with these fields:
	--   pathIn               = pathToInputFile       -- [Required] Specify "-" to use stdin.
	--   pathOut              = pathToOutputFile      -- [Required] Specify "-" to use stdout. (Note that if stdout is used then anything you print() in the metaprogram will end up there.)
	--   pathMeta             = pathForMetaprogram    -- [Optional] You can inspect this temporary output file if an error occurs in the metaprogram.
	--
	--   debug                = boolean               -- [Optional] Debug mode. The metaprogram file is formatted more nicely and does not get deleted automatically.
	--   addLineNumbers       = boolean               -- [Optional] Add comments with line numbers to the output.
	--
	--   backtickStrings      = boolean               -- [Optional] Enable the backtick (`) to be used as string literal delimiters. Backtick strings don't interpret any escape sequences and can't contain other backticks. (Default: false)
	--   jitSyntax            = boolean               -- [Optional] Allow LuaJIT-specific syntax. (Default: false)
	--   canOutputNil         = boolean               -- [Optional] Allow !(expression) and outputValue() to output nil. (Default: true)
	--   fastStrings          = boolean               -- [Optional] Force fast serialization of string values. (Non-ASCII characters will look ugly.) (Default: false)
	--   validate             = boolean               -- [Optional] Validate output. (Default: true)
	--   strictMacroArguments = boolean               -- [Optional] Check that macro arguments are valid Lua expressions. (Default: true)
	--
	--   macroPrefix          = prefix                -- [Optional] String to prepend to macro names. (Default: "")
	--   macroSuffix          = suffix                -- [Optional] String to append  to macro names. (Default: "")
	--
	--   release              = boolean               -- [Optional] Enable release mode. Currently only disables the @@ASSERT() macro when true. (Default: false)
	--   logLevel             = levelName             -- [Optional] Maximum log level for the @@LOG() macro. Can be "off", "error", "warning", "info", "debug" or "trace". (Default: "trace", which enables all logging)
	--
	--   onInsert             = function( name )      -- [Optional] Called for each @insert"name" instruction. It's expected to return a Lua code string. By default 'name' is a path to a file to be inserted.
	--   onBeforeMeta         = function( luaString ) -- [Optional] Called before the metaprogram runs, if a metaprogram is generated. luaString contains the metaprogram.
	--   onAfterMeta          = function( luaString ) -- [Optional] Here you can modify and return the Lua code before it's written to 'pathOut'.
	--   onError              = function( error )     -- [Optional] You can use this to get traceback information. 'error' is the same value as what is returned from processFile().
	--
	processFile = processFile,

	-- processString()
	-- Process Lua code. Returns nil and a message on error.
	--
	-- luaString, info = processString( params )
	-- info: Table with various information. (See 'ProcessInfo' for more info.)
	--
	-- params: Table with these fields:
	--   code                 = luaString             -- [Required]
	--   pathMeta             = pathForMetaprogram    -- [Optional] You can inspect this temporary output file if an error occurs in the metaprogram.
	--
	--   debug                = boolean               -- [Optional] Debug mode. The metaprogram file is formatted more nicely and does not get deleted automatically.
	--   addLineNumbers       = boolean               -- [Optional] Add comments with line numbers to the output.
	--
	--   backtickStrings      = boolean               -- [Optional] Enable the backtick (`) to be used as string literal delimiters. Backtick strings don't interpret any escape sequences and can't contain other backticks. (Default: false)
	--   jitSyntax            = boolean               -- [Optional] Allow LuaJIT-specific syntax. (Default: false)
	--   canOutputNil         = boolean               -- [Optional] Allow !(expression) and outputValue() to output nil. (Default: true)
	--   fastStrings          = boolean               -- [Optional] Force fast serialization of string values. (Non-ASCII characters will look ugly.) (Default: false)
	--   validate             = boolean               -- [Optional] Validate output. (Default: true)
	--   strictMacroArguments = boolean               -- [Optional] Check that macro arguments are valid Lua expressions. (Default: true)
	--
	--   macroPrefix          = prefix                -- [Optional] String to prepend to macro names. (Default: "")
	--   macroSuffix          = suffix                -- [Optional] String to append  to macro names. (Default: "")
	--
	--   release              = boolean               -- [Optional] Enable release mode. Currently only disables the @@ASSERT() macro when true. (Default: false)
	--   logLevel             = levelName             -- [Optional] Maximum log level for the @@LOG() macro. Can be "off", "error", "warning", "info", "debug" or "trace". (Default: "trace", which enables all logging)
	--
	--   onInsert             = function( name )      -- [Optional] Called for each @insert"name" instruction. It's expected to return a Lua code string. By default 'name' is a path to a file to be inserted.
	--   onBeforeMeta         = function( luaString ) -- [Optional] Called before the metaprogram runs, if a metaprogram is generated. luaString contains the metaprogram.
	--   onError              = function( error )     -- [Optional] You can use this to get traceback information. 'error' is the same value as the second returned value from processString().
	--
	processString = processString,

	-- Values.
	----------------------------------------------------------------

	VERSION         = PP_VERSION, -- The version of LuaPreprocess.
	metaEnvironment = metaEnv,    -- The environment used for metaprograms.
}

-- Include all functions from the metaprogram environment.
for k, v in pairs(metaFuncs) do  pp[k] = v  end

return pp



--[[!===========================================================

Copyright © 2018-2022 Marcus 'ReFreezed' Thunström

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
