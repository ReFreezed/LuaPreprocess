--==============================================================
--=
--=  Test suite for LuaPreprocess
--=
--==============================================================

io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

local ppChunk    = assert(loadfile"preprocess.lua")
local results    = {}
local luaExe     = "lua"
local enableInts = _VERSION >= "Lua 5.3"

for i = -1, -1/0, -1 do
	if not arg[i] then  break  end
	luaExe = arg[i]
end



local function doTest(description, f, ...)
	print("Running test: "..description)

	local ok, err = pcall(f, ...)
	if not ok then  print("Error: "..tostring(err))  end

	table.insert(results, {description=description, ok=ok})
end
local function doTestUnprotected(description, f, ...)
	print("Running test: "..description)
	f(...)
	table.insert(results, {description=description, ok=true})
end
local function doTestDisabled()
	-- void
end
local function addLabel(label)
	table.insert(results, {label=label})
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readFile(path)
	local file = assert(io.open(path, "rb"))
	local data = file:read("*a")
	file:close()
	return data
end
local function writeFile(path, data)
	local file = assert(io.open(path, "wb"))
	file:write(data)
	file:close()
end
local function fileExists(path)
	local file = io.open(path, "rb")
	if not file then  return false  end
	file:close()
	return true
end
local function removeFile(path)
	if not fileExists(path) then  return  end
	assert(os.remove(path))
end

local function assertCodeOutput(codeOut, codeExpected, message)
	if trim(codeOut) ~= codeExpected then
		error(message or "Unexpected output: "..codeOut, 2)
	end
end

-- command = createCommand( program, rest )
local function createCommand(program, rest)
	return program:find(" ", 1, true)
	       and '""'..program..'" '..rest..'"'
	       or  program..' '..rest
end

local function _runCommand(program, rest, expectSuccess)
	local cmd = createCommand(program, rest)
	print("Running command: "..cmd)

	if jit or _VERSION >= "Lua 5.2" then
		local ok, termination, code = os.execute(cmd)
		if ((ok or false) and termination == "exit" and code == 0) == expectSuccess then  -- void
		elseif expectSuccess then  error("Command failed (termination="..tostring(termination)..", code="..tostring(code).."): "..cmd, 2)
		else                       error("Command succeeded unexpectedly: "..cmd, 2)  end
	else
		local code = os.execute(cmd)
		if (code == 0) == expectSuccess then  -- void
		elseif expectSuccess then  error("Command failed (code="..code.."): "..cmd, 2)
		else                       error("Command succeeded unexpectedly: "..cmd, 2)  end
	end
end
local function runCommand(program, rest)
	_runCommand(program, rest, true)
end
local function runCommandToFail(program, rest)
	_runCommand(program, rest, false)
end
local function runCommandAndSendData(luaExe, rest, dataStr)
	local cmd = createCommand(luaExe, rest)
	print("Running command: "..cmd)
	local handle = assert(io.popen(cmd, "w"))
	handle:write(dataStr)
	handle:close()
end

local function requireNewTemp(moduleName)
	local oldModule            = package.loaded[moduleName]
	package.loaded[moduleName] = nil
	local tempModule           = require(moduleName)
	package.loaded[moduleName] = oldModule
	return tempModule
end

--==============================================================



addLabel("Preprocessor code")

doTest("Inline block with simple expression", function()
	local pp = ppChunk()
	local luaIn = [[
		local x = !(1+2*3)
	]]

	local luaOut = assert(pp.processString{ code=luaIn })
	assertCodeOutput(luaOut, [[local x = 7]])
end)

doTest("Static branch", function()
	local pp = ppChunk()
	local luaIn = [[
		!if FLAG then
			print("Yes")
		!else
			print("No")
		!end
	]]

	pp.metaEnvironment.FLAG = true
	local luaOut = assert(pp.processString{ code=luaIn })
	assertCodeOutput(luaOut, [[print("Yes")]], "Unexpected output with FLAG=true.")

	pp.metaEnvironment.FLAG = false
	local luaOut = assert(pp.processString{ code=luaIn })
	assertCodeOutput(luaOut, [[print("No")]], "Unexpected output with FLAG=false.")
end)

doTest("Output value from metaprogram", function()
	local pp = ppChunk()
	local luaIn = [[
		!local t = {
			z = 99,
			a = 2,
		}
		local theTable = !(t)
	]]

	local luaOut = assert(pp.processString{ code=luaIn })
	-- Table keys should be sorted. We want consistent output!
	assertCodeOutput(luaOut, [[local theTable = {a=2,z=99}]])
end)

doTest("Generate code", function()
	local pp = ppChunk()

	local luaOut = assert(pp.processString{ code=[[
		!(
		outputLua("local s = ")
		outputValue("\n")
		)
	]] })
	assertCodeOutput(luaOut, [[local s = "\n"]])

	local luaOut = assert(pp.processString{ code=[[
		!(
		outputLua("local s1, s2 = ")
		outputValue("\001", "\0002")
		)
	]] })
	assertCodeOutput(luaOut, [[local s1, s2 = "\1","\0002"]])
end)

doTest("Parsing extended preprocessor line", function()
	local pp = ppChunk()
	local luaIn = [[
		!local str = "foo\
		"; local arr = {
			10,
		}; local z = (
			100+(3^3)
		)+arr[
			1
		]; --[=[ Comment in metaprogram.
		]=]

		local z = !(z)
	]]

	local luaOut = assert(pp.processString{ code=luaIn })
	assertCodeOutput(luaOut, enableInts and [[local z = 137.0]] or [[local z = 137]])
end)

doTest("Dual code", function()
	local pp = ppChunk()

	local luaOut = assert(pp.processString{ code=[[
		!local  one = 1
		!local  two = 2
		!!local sum = one+two -- The expression is evaluated in the metaprogram.
	]]})
	assertCodeOutput(luaOut, [[local sum = 3]])

	local luaOut = assert(pp.processString{ code=[[
		!!local n, s = 5^5, "foo".."bar";
	]]})
	assertCodeOutput(luaOut, enableInts and [[local n, s = 3125.0, "foobar";]] or [[local n, s = 3125, "foobar";]])

	-- Invalid: Duplicate names.
	assert(not pp.processString{ code=[[ !!x, y, x = 0 ]]})
end)

doTest("Expression or not?", function()
	local pp = ppChunk()

	local luaOut = assert(pp.processString{ code=[[
		foo(!( math.floor(1.5) ))
	]]})
	assertCodeOutput(luaOut, [[foo(1)]])

	local luaOut = assert(pp.processString{ code=[[
		!( math.floor(1.5); )
	]]})
	assertCodeOutput(luaOut, [[]])

	local luaOut = assert(pp.processString{ code=[[
		!( x = math.floor(1.5) )
	]]})
	assertCodeOutput(luaOut, [[]])

	-- Invalid: Comma-separated expressions are ambiguous.
	assert(not pp.processString{ code=[[ x = !(1, 2)      ]]})
	assert(not pp.processString{ code=[[ x = !!("a", "b") ]]})

	-- Invalid: !!() must always have an expression.
	assert(not pp.processString{ code=[[ !!( x = y ) ]]})
end)

doTest("Output values of different types", function()
	local pp = ppChunk()

	-- Valid: Numbers, strings, tables, booleans, nil.

	local luaOut = assert(pp.processString{ code=[[ num = !(123) ]]})
	assertCodeOutput(luaOut, [[num = 123]])

	local luaOut = assert(pp.processString{ code=[[ str = !("foo") ]]})
	assertCodeOutput(luaOut, [[str = "foo"]])

	local luaOut = assert(pp.processString{ code=[[ t = !({}) ]]})
	assertCodeOutput(luaOut, [[t = {}]])

	local luaOut = assert(pp.processString{ code=[[ bool, nothing = !(true), !(nil) ]]})
	assertCodeOutput(luaOut, [[bool, nothing = true, nil]])

	-- Invalid: Functions, userdata, coroutines.

	assert(not pp.processString{ code=[[ func = !(function()end)                   ]]})
	assert(not pp.processString{ code=[[ file = !(io.stdout)                       ]]})
	assert(not pp.processString{ code=[[ co   = !(coroutine.create(function()end)) ]]})
end)

doTest("Preprocessor keywords", function()
	local pp = ppChunk()

	local luaOut = assert(pp.processString{ code=[[ filename = @file ]]})
	assertCodeOutput(luaOut, [[filename = "<code>"]]) -- Note: The dummy value when we have no real path may change in the future.

	local luaOut = assert(pp.processString{ code=[[ ln = @line ]]})
	assertCodeOutput(luaOut, [[ln =  1]])

	local luaOut = assert(pp.processString{ code=[[ lnStr = @file..@line..@line..@file ]]})
	assertCodeOutput(luaOut, [[lnStr = "<code>".. 1 .. 1 .."<code>"]])

	local luaOut = assert(pp.processString{
		code     = [[ v = @insert "foo" ]],
		onInsert = function(name)  return name  end,
	})
	assertCodeOutput(luaOut, [[v = foo]])

	local luaOut = assert(pp.processString{
		code     = [[ v = @@"foo" ]],
		onInsert = function(name)  return name  end,
	})
	assertCodeOutput(luaOut, [[v = foo]])

	-- Invalid: Bad keyword.
	assert(not pp.processString{ code=[[ @bad ]]})

	-- Invalid: Bad insert value.
	assert(not pp.processString{ code=[[ @insert 1   ]]})
	assert(not pp.processString{ code=[[ @insert {}  ]]})
	assert(not pp.processString{ code=[[ @insert (1) ]]})
	assert(not pp.processString{ code=[[ @insert nil ]]})
end)

doTest("Macros", function()
	local pp = ppChunk()

	local luaOut = assert(pp.processString{ code=[[
		!function JOIN(ident1, ident2)  return ident1..ident2  end
		v = @insert JOIN(foo, bar)
	]]})
	assertCodeOutput(luaOut, [[v = foobar]])

	local luaOut = assert(pp.processString{ code=[[
		!function JOIN(ident1, ident2)  return ident1..ident2  end
		v = @@JOIN(foo, bar)
	]]})
	assertCodeOutput(luaOut, [[v = foobar]])

	-- Macro variants.
	local luaOut = assert(pp.processString{ code=[[
		!function ECHO(v)  return v  end
		s = @@ECHO""
	]]})
	assertCodeOutput(luaOut, [[s = ""]])

	local luaOut = assert(pp.processString{ backtickStrings=true, code=[[
		!function ECHO(v)  return v  end
		s = @@ECHO``
	]]})
	assertCodeOutput(luaOut, [[s = ""]])

	local luaOut = assert(pp.processString{ code=[[
		!function ECHO(v)  return v  end
		t = @@ECHO{}
	]]})
	assertCodeOutput(luaOut, [[t = {}]])

	-- Macro name with lookups.
	local luaOut = assert(pp.processString{ code=[[
		!t, a = {t={o={m=function(o,v) return v end}}}, {"o"}
		v = @@t.t[ a[1] ]:m(foo)
	]]})
	assertCodeOutput(luaOut, [[v = foo]])

	assert(not pp.processString{ code=[[
		!t = {f=function(v) return v end}
		v = @@t.(foo)
	]]})
	assert(not pp.processString{ code=[[
		!t = {o={m=function(o,v) return v end}}
		v = @@t.o:(foo)
	]]})

	-- Function as an argument.
	local luaOut = assert(pp.processString{ code=[[
		!function ECHO(v)  return v  end
		f = @@ECHO(function() return a,b end)
	]]})
	assertCodeOutput(luaOut, [[f = function() return a,b end]])

	local luaOut = assert(pp.processString{ backtickStrings=true, code=[[
		!function ECHO(v)  return v  end
		f = @@ECHO(function() return a,`b` end)
	]]})
	assertCodeOutput(luaOut, [[f = function() return a,"b" end]])

	-- Nested macros.
	local luaOut = assert(pp.processString{ code=[[
		!function DOUBLE(ident)  return ident.."_"..ident  end
		v = @@DOUBLE(@@DOUBLE(@@DOUBLE(woof)))
	]]})
	assertCodeOutput(luaOut, [[v = woof_woof_woof_woof_woof_woof_woof_woof]])

	-- Metaprogram code in macros.
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !(  1 ) )                 ]]}), [[n = 1]]            )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !!("1") )                 ]]}), [[n = 1]]            )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !(  1 ) }                 ]]}), [[n = { 1 }]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !!("1") }                 ]]}), [[n = { 1 }]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !(  1 ) + 2 )             ]]}), [[n = 1 + 2]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !!("1") + 2 )             ]]}), [[n = 1 + 2]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !(  1 ) + 2 }             ]]}), [[n = { 1 + 2 }]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !!("1") + 2 }             ]]}), [[n = { 1 + 2 }]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( 1 + !(  2 ) )             ]]}), [[n = 1 + 2]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( 1 + !!("2") )             ]]}), [[n = 1 + 2]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ 1 + !(  2 ) }             ]]}), [[n = { 1 + 2 }]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ 1 + !!("2") }             ]]}), [[n = { 1 + 2 }]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( 1 + !(  2 ) + 3 )         ]]}), [[n = 1 + 2 + 3]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( 1 + !!("2") + 3 )         ]]}), [[n = 1 + 2 + 3]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ 1 + !(  2 ) + 3 }         ]]}), [[n = { 1 + 2 + 3 }]])
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ 1 + !!("2") + 3 }         ]]}), [[n = { 1 + 2 + 3 }]])
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !!("1")!!("+")!!("2") )   ]]}), [[n = 1+2]]          )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !!("1")!!("+")!!("2") }   ]]}), [[n = { 1+2 }]]      )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !(do outputLua"1" end) )  ]]}), [[n = 1]]            )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !(do outputLua"1" end) }  ]]}), [[n = { 1 }]]        )

	local luaOut = assert(pp.processString{ code=[[
		!function ECHO(v)  return v  end
		n = @@ECHO(
			!outputLua("1")
		)
	]]})
	assertCodeOutput(luaOut, [[n = 1]])

	-- Prefixes/suffixes.
	assert(pp.processString{ macroPrefix="MACRO_", code=[[
		!local function MACRO_FOO() return "" end
		@@FOO()
	]]})
	assert(pp.processString{ macroSuffix="_MACRO", code=[[
		!local function FOO_MACRO() return "" end
		@@FOO()
	]]})

	-- Non-strict macro arguments.
	local code = [[
		!function BINOP(operator, a, b)  return a..operator..b  end
		v = @@BINOP(^, 3, 2)
	]]
	assertCodeOutput(assert(    pp.processString{ strictMacroArguments=false, code=code}), [[v = 3^2]])
	assert                 (not pp.processString{ strictMacroArguments=true , code=code})

	local code = [[
		!function ECHO3(a,b,c)  return a..b..c  end
		foo @@ECHO3( ,--[=[]=](),)
	]]
	assertCodeOutput(assert(    pp.processString{ strictMacroArguments=false, code=code}), [[foo ()]])
	assert                 (not pp.processString{ strictMacroArguments=true , code=code})

	-- Invalid: Ambiguous syntax.
	assert(not pp.processString{ code=[[
		!function VOID()  return ""  end
		v = @@VOID
		() 1
	]]})
	assert(not pp.processString{ code=[[
		!t = {o={m=function(o,v) return v end}}
		v = @@t.o:m
		(foo)
	]]})

	-- Invalid: Preprocessor code inside macro name expression.
	assert(not pp.processString{ code=[[
		!function bad()  return "f"  end
		!t = {f=function(v) return v end}
		v = @@t[ @@bad() ](foo)
	]]})

	-- Invalid: Bad macro arguments format.
	assert(not pp.processString{ code=[[ @insert type[]   ]]})
	assert(not pp.processString{ code=[[ @insert type + 1 ]]})

	-- Invalid: Invalid value from code block in macro.
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO(!!(1))  ]]})

	-- Invalid: Nested code block in macro.
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO( !!( !(1) ) )  ]]})

	-- Using outputLua().
	assertCodeOutput(assert(pp.processString{ code=[[  !(function Y() return   ("y") end)  x = @@Y()  ]]}), [[x = y]])
	assertCodeOutput(assert(pp.processString{ code=[[  !(function Y() outputLua("y") end)  x = @@Y()  ]]}), [[x = y]])

	-- Invalid: Both using outputLua() and returning code.
	assert(not pp.processString{ code=[[  !(function Y() outputLua("y") ; return "z" end)  x = @@Y()  ]]})
end)

doTest("Predefined macros", function()
	local pp = ppChunk()

	-- @@ASSERT()
	assertCodeOutput(assert(pp.processString{ code=[[ @@ASSERT(foo)                             ]]}), [[if not (foo) then  error("Assertion failed: foo")  end]])
	assertCodeOutput(assert(pp.processString{ code=[[ @@ASSERT(foo ~= "good", "Bad foo: "..foo) ]]}), [[if not (foo ~= "good") then  error(("Bad foo: "..foo))  end]])

	-- @@LOG()
	assertCodeOutput(assert(pp.processString{ logLevel="error",   code=[[ @@LOG("warning", "Uh oh!")          ]]}), [[]])
	assertCodeOutput(assert(pp.processString{ logLevel="warning", code=[[ @@LOG("warning", "Uh oh!")          ]]}), [[print("Uh oh!")]])
	assertCodeOutput(assert(pp.processString{                     code=[[ @@LOG("warning", "Number: %d", num) ]]}), [[print(string.format("Number: %d", num))]])

	-- Invalid: Bad log level.
	assert(not pp.processString{ logLevel="bad", code=""})
end)

doTest("Preprocessor symbols", function()
	local pp = ppChunk()

	local luaOut = assert(pp.processString{ code=[[
		!local FOO = "y"
		x = $FOO
	]]})
	assertCodeOutput(luaOut, [[x = y]])

	local luaOut = assert(pp.processString{ code=[[
		!local function FOO()  return "y"  end
		x = $FOO
	]]})
	assertCodeOutput(luaOut, [[x = y]])

	local luaOut = assert(pp.processString{ code=[[
		!local FOO = setmetatable({}, {__call=function()  return "y"  end})
		x = $FOO
	]]})
	assertCodeOutput(luaOut, [[x = y]])

	-- Invalid: Symbols must result in strings.
	assert(not pp.processString{ code=[[
		!local BAD = 840
		v = $BAD
	]]})
	assert(not pp.processString{ code=[[
		!local function BAD()  return 840  end
		v = $BAD
	]]})
	assert(not pp.processString{ code=[[
		!local BAD = {}
		v = $BAD
	]]})
end)



addLabel("Library API")

doTest("Processing calls", function()
	local pp              = ppChunk()
	pp.metaEnvironment.pp = pp

	-- Path collisions.
	writeFile("temp/generatedTest.lua2p", [[]])
	assert(    pp.processFile{ pathIn="temp/generatedTest.lua2p", pathOut="temp/generatedTest.lua"  , pathMeta=nil })
	assert(    pp.processFile{ pathIn="temp/generatedTest.lua2p", pathOut="temp/generatedTest.lua"  , pathMeta="temp/generatedTest.meta.lua" })
	assert(not pp.processFile{ pathIn="temp/generatedTest.lua2p", pathOut="temp/generatedTest.lua2p", pathMeta=nil })
	assert(not pp.processFile{ pathIn="temp/generatedTest.lua2p", pathOut="temp/generatedTest.lua"  , pathMeta="temp/generatedTest.lua2p" })
	assert(not pp.processFile{ pathIn="temp/generatedTest.lua2p", pathOut="temp/generatedTest.lua"  , pathMeta="temp/generatedTest.lua" })

	-- Recursive processing is not supported.
	assert(not pp.processString{ code=[[
		!pp.processString{ code="" }
	]]})

	-- Callback: onBeforeMeta should only fire if there's preprocessor code.
	local fired = false ; assert(pp.processString{ onBeforeMeta=function()fired=(true)end, code=[[ n = !(@line) ]]}) ; assert(    fired)
	local fired = false ; assert(pp.processString{ onBeforeMeta=function()fired=(true)end, code=[[ n =  (@line) ]]}) ; assert(    fired)
	local fired = false ; assert(pp.processString{ onBeforeMeta=function()fired=(true)end, code=[[ n =  (1    ) ]]}) ; assert(not fired)
end)

doTest("Create tokens", function()
	local pp = ppChunk()

	local function assertToken(tok, tokType, v, repr, extraK, extraV)
		if tok.type           ~= tokType then  error(tok.type,              2) end
		if tok.value          ~= v       then  error(tok.value,             2) end
		if tok.representation ~= repr    then  error(tok.representation,    2) end
		if tok[extraK]        ~= extraV  then  error(tostring(tok[extraK]), 2) end
	end

	assert(not pcall(pp.newToken, "bad", nil))

	-- Comment.
	assertToken(pp.newToken("comment", "foo",        false), "comment", "foo",        "--foo\n",            "long", false)
	assertToken(pp.newToken("comment", "foo",        true ), "comment", "foo",        "--[[foo]]",          "long", true )
	assertToken(pp.newToken("comment", "foo\nbar",   false), "comment", "foo\nbar",   "--[[foo\nbar]]",     "long", true )
	assertToken(pp.newToken("comment", "foo\nbar]]", false), "comment", "foo\nbar]]", "--[=[foo\nbar]]]=]", "long", true )

	-- Identifier.
	assertToken(pp.newToken("identifier", "foo"), "identifier", "foo", "foo", nil, nil)

	assert(not pcall(pp.newToken, "identifier", "if"))

	-- Keyword.
	assertToken(pp.newToken("keyword", "if"), "keyword", "if", "if", nil, nil)

	assert(not pcall(pp.newToken, "keyword", "bad"))

	-- Number.
	assertToken(pp.newToken("number", 42,    "auto" ), "number", 42,    "42",      nil, nil)
	assertToken(pp.newToken("number", -1.25, "auto" ), "number", -1.25, "-1.25",   nil, nil)
	assertToken(pp.newToken("number", 5.75,  "e"    ), "number", 5.75,  "5.75e+0", nil, nil)
	assertToken(pp.newToken("number", 255,   "HEX"  ), "number", 255,   "0xFF",    nil, nil)
	assertToken(pp.newToken("number", 1/0,   "auto" ), "number", 1/0,   "(1/0)",   nil, nil)
	assertToken(pp.newToken("number", -1/0,  "float"), "number", -1/0,  "(-1/0)",  nil, nil)

	local tok = pp.newToken("number", 0/0, "hex")
	assert(tok.type           == "number",  tok.type)
	assert(tok.value          ~= tok.value, tok.value)
	assert(tok.representation == "(0/0)",   tok.representation)

	-- Punctuation.
	assertToken(pp.newToken("punctuation", "=="), "punctuation", "==", "==", nil, nil)

	assert(not pcall(pp.newToken, "punctuation", "!="))

	-- String.
	assertToken(pp.newToken("string", "foo",       false), "string", "foo",       '"foo"',         "long", false)
	assertToken(pp.newToken("string", 'foo"\nbar', false), "string", 'foo"\nbar', "'foo\"\\nbar'", "long", false)
	assertToken(pp.newToken("string", "foo",       true ), "string", "foo",       "[[foo]]",       "long", true )
	assertToken(pp.newToken("string", "foo]]",     true ), "string", "foo]]",     "[=[foo]]]=]",   "long", true )

	assertToken(
		pp.newToken("string", "\0\1\2\3\4\5\6\7\8\9\10\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\0310\127", false),
		"string",
		"\0\1\2\3\4\5\6\7\8\9\10\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\0310\127",
		[["\0\1\2\3\4\5\6\a\b\t\n\v\f\r\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\0310\127"]],
		"long", false
	)

	-- Whitespace.
	assertToken(pp.newToken("whitespace", "\t \n"), "whitespace", "\t \n", "\t \n", nil, nil)

	assert(not pcall(pp.newToken, "whitespace", "bad"))

	-- Preprocessor entry.
	assertToken(pp.newToken("pp_entry", false), "pp_entry", "!",  "!",  "double", false)
	assertToken(pp.newToken("pp_entry", true ), "pp_entry", "!!", "!!", "double", true )

	-- Preprocessor keyword.
	assertToken(pp.newToken("pp_keyword", "line"), "pp_keyword", "line",   "@line", nil, nil)
	assertToken(pp.newToken("pp_keyword", "@"   ), "pp_keyword", "insert", "@@",    nil, nil)

	assert(not pcall(pp.newToken, "pp_keyword", "bad"))

	-- Preprocessor symbol.
	assertToken(pp.newToken("pp_symbol", "foo"), "pp_symbol", "foo", "$foo", nil, nil)

	assert(not pcall(pp.newToken, "pp_symbol", ""))
	assert(not pcall(pp.newToken, "pp_symbol", "if"))
	assert(not pcall(pp.newToken, "pp_symbol", "$foo"))
end)

doTest("Get useful tokens", function()
	local pp     = ppChunk()
	local tokens = pp.tokenize[[local x = 5 -- Foo!]]

	pp.removeUselessTokens(tokens)

	assert(#tokens == 4, "Unexpected token count.")
	assert(tokens[1].type  == "keyword",     "Unexpected token type 1.")
	assert(tokens[1].value == "local",       "Unexpected token value 1.")
	assert(tokens[2].type  == "identifier",  "Unexpected token type 2.")
	assert(tokens[2].value == "x",           "Unexpected token value 2.")
	assert(tokens[3].type  == "punctuation", "Unexpected token type 3.")
	assert(tokens[3].value == "=",           "Unexpected token value 3.")
	assert(tokens[4].type  == "number",      "Unexpected token type 4.")
	assert(tokens[4].value == 5,             "Unexpected token value 4.")
end)

doTest("Serialize", function()
	local pp = ppChunk()

	local t = {
		z     = 99,
		a     = 2,
		["f"] = 176,
	}

	local luaOut = assert(pp.toLua(t))
	assertCodeOutput(luaOut, [[{a=2,f=176,z=99}]]) -- Note: Table keys should be sorted.
end)

doTest("Output interception", function()
	local pp = ppChunk()

	local luaOut = assert(pp.processString{ code=[[
		!startInterceptingOutput()
		local foo  = bar
		!local lua = stopInterceptingOutput():gsub("(%a+) *= *(%a+)", "%2 = %1")
		$lua
	]] })
	assertCodeOutput(luaOut, [[local bar = foo]])

	-- Invalid: Unbalanced interception start/stop calls.
	assert(not pp.processString{ code=[[ !startInterceptingOutput() ]]})
	assert(not pp.processString{ code=[[ !stopInterceptingOutput()  ]]})
end)

doTest("Resources and evaluation", function()
	local pp = ppChunk()

	assert(pp.processString{
		code     = [[ !assert(loadResource("x=x+1") == "x=x+1") ]],
		onInsert = function(name)  return name  end,
	})

	_G.   x = 8 ; assert(pp.evaluate("2^x"       ) == 2^x) ; _G.x = nil
	local x = 8 ; assert(pp.evaluate("2^x", {x=x}) == 2^x)
	assert(not pp.evaluate("2^x")) -- (Global) x should be nil.

	local v, err = pp.evaluate("")
	assert(not v)
	assert(err)

	if jit then
		assert(         assert(pp.evaluate"0b101"   )  == 5)
		assert(tonumber(assert(pp.evaluate"123ULL"  )) == 123)
		assert(tonumber(assert(pp.evaluate"0x123ULL")) == 0x123)
	end
end)

doTest("Indentation", function()
	local pp = ppChunk()

	assert(pp.getIndentation(" \t foo") == " \t ")
	assert(pp.getIndentation(" \n foo") == " ")

	assertCodeOutput(assert(pp.processString{ code=    "\t   \tindent = !(getCurrentIndentationInOutput(4))"    }), [[indent = 8]])
	assertCodeOutput(assert(pp.processString{ code="\n\n\t   \tindent = !(getCurrentIndentationInOutput(4))\n\n"}), [[indent = 8]])

	-- Spaces.
	local indent, expect = pp.getIndentation(""        , 4), 0  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation(" "       , 4), 1  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation("  "      , 4), 2  ; if indent ~= expect then  error(expect.." "..indent)  end

	-- Tab last.
	local indent, expect = pp.getIndentation("\t"      , 4), 4  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation(" \t"     , 4), 4  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation("  \t"    , 4), 4  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation("   \t"   , 4), 4  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation("    \t"  , 4), 8  ; if indent ~= expect then  error(expect.." "..indent)  end

	-- Two tabs.
	local indent, expect = pp.getIndentation("\t\t"    , 4), 8  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation("\t \t"   , 4), 8  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation("\t  \t"  , 4), 8  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation("\t   \t" , 4), 8  ; if indent ~= expect then  error(expect.." "..indent)  end
	local indent, expect = pp.getIndentation("\t    \t", 4), 12 ; if indent ~= expect then  error(expect.." "..indent)  end
end)

doTest("Misc.", function()
	local pp = ppChunk()

	-- metaEnvironment is a shallow copy of _G.
	assert(pp.metaEnvironment       ~= _G)
	assert(pp.metaEnvironment.table == table)

	-- Natural comparisons.
	assert(                 ("foo9" < "foo10") == false)
	assert(pp.compareNatural("foo9",  "foo10") == true )

	do
		local keys  = {"a2", "b", "a10", "-"}
		local map   = {a2=2, b=4, a10=3, ["-"]=1}
		local count = 0

		pp.sortNatural(keys)

		for k, order in pp.pairsSorted(map) do
			count = count + 1
			assert(order       == count)
			assert(keys[order] == k)
		end
	end

	-- Current output.
	assertCodeOutput(assert(pp.processString{ code="x = 1 ; y = !(getOutputSoFar())"                                               }), 'x = 1 ; y = "x = 1 ; y = "')
	assertCodeOutput(assert(pp.processString{ code="x = !(getOutputSoFarOnLine        ())\n\ty = !(getOutputSoFarOnLine        ())"}), 'x = "x = "\n\ty = "\\ty = "')
	assertCodeOutput(assert(pp.processString{ code="x = !(getCurrentLineNumberInOutput())\n\ty = !(getCurrentLineNumberInOutput())"}), "x = 1\n\ty = 2")

	assert(pp.processString{ code=[[
		x = 1
		!(
		local buffer = {}
		getOutputSoFar(buffer)
		assert(table.concat(buffer):find"^%s*x = 1%s*$")
		)
		y = 2
	]]})

	-- Macros.
	local luaOut = assert(pp.processString{ code=[[
		!!(callMacro("ASSERT", "x", "foo()"))
	]]})
	assertCodeOutput(luaOut, [[if not (x) then  error((foo()))  end]])

	local luaOut = assert(pp.processString{ code=[[
		!!(callMacro(ASSERT, "x", "foo()"))
	]]})
	assertCodeOutput(luaOut, [[if not (x) then  error((foo()))  end]])

	local luaOut = assert(pp.processString{ code=[[
		!callMacro(ASSERT, "x", "foo()")
	]]})
	assertCodeOutput(luaOut, [[]])

	local luaOut = assert(pp.processString{ macroPrefix="MACRO_", code=[[
		!function _G.MACRO_MOO() return "foo()" end -- Must be global!
		!!(callMacro("MOO"))
	]]})
	assertCodeOutput(luaOut, [[foo()]])
	pp.metaEnvironment.MACRO_MOO = nil

	local luaOut = assert(pp.processString{ macroPrefix="MACRO_", code=[[
		!local function MACRO_MOO() return "foo()" end
		!!(callMacro(MACRO_MOO))
	]]})
	assertCodeOutput(luaOut, [[foo()]])

	assert(not pp.processString{ macroPrefix="MACRO_", code=[[
		!local function MACRO_MOO() return "foo()" end -- Not a global!
		!!(callMacro("MOO"))
	]]})

	assert(not pp.processString{ macroPrefix="MACRO_", code=[[
		!function _G.MACRO_MOO() return "foo()" end
		!!(callMacro("MACRO_MOO")) -- Calls MACRO_MACRO_MOO!
	]]})
	pp.metaEnvironment.MACRO_MOO = nil

	-- Processing, or not processing... that's the real question here, mate.
	assert(not pp.isProcessing())
	assert(pp.processString{ code=[[ !assert(isProcessing()) ]]})
	assert(not pp.isProcessing())
end)



addLabel("Command line")

doTest("Simple processing of single file", function()
	writeFile("temp/generatedTest.lua2p", [[
		!outputLua("math.floor(1.5)")
	]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])

	assertCodeOutput(readFile"temp/generatedTest.lua", [[math.floor(1.5)]])
end)

doTest("Send data", function()
	writeFile("temp/generatedTest.lua2p", [[
		print(!(dataFromCommandLine))
	]])
	runCommand(luaExe, [[preprocess-cl.lua --outputpaths --data="Hello, world!" temp/generatedTest.lua2p temp/generatedTest.lua]])

	assertCodeOutput(readFile"temp/generatedTest.lua", [[print("Hello, world!")]])
end)

doTest("Handler + multiple files", function()
	writeFile("temp/generatedHandler.lua", [[
		_G.one = 1
		return {
			aftermeta = function(path, luaString)
				print(path, luaString)
				return 'print("foo");'..luaString -- Prepend some code.
			end,
		}
	]])
	writeFile("temp/generatedTest1.lua2p", [[!!local x = one+2*3]])
	writeFile("temp/generatedTest2.lua2p", [[!!local y = one+2^10]])

	runCommand(luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua temp/generatedTest1.lua2p temp/generatedTest2.lua2p --debug]])

	assertCodeOutput(readFile"temp/generatedTest1.lua", [[print("foo");local x = 7]])
	assertCodeOutput(readFile"temp/generatedTest2.lua", enableInts and [[print("foo");local y = 1025.0]] or [[print("foo");local y = 1025]])
end)

doTest("stdin and stdout", function()
	runCommandAndSendData(luaExe, [[preprocess-cl.lua - >temp\generatedTest.lua]], [[ x = !(1+2) ]])
	assertCodeOutput(readFile"temp/generatedTest.lua", [[x = 3]])
end)

doTest("Options", function()
	--backtickstrings
	writeFile("temp/generatedTest.lua2p", [[
		s = `
		foo\`
	]])
	runCommandToFail(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])
	runCommand      (luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --backtickstrings]])
	assertCodeOutput(readFile"temp/generatedTest.lua", [[s = "\n\t\tfoo\\"]])

	--data
	writeFile("temp/generatedTest.lua2p", [[ v = !(dataFromCommandLine) ]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])            ; assertCodeOutput(readFile"temp/generatedTest.lua", [[v = nil]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --data=foo]]) ; assertCodeOutput(readFile"temp/generatedTest.lua", [[v = "foo"]])

	--faststrings (Just test for errors.)
	writeFile("temp/generatedTest.lua2p", [[ s = !("\255") ]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --faststrings]])

	--jitsyntax
	if jit then
		writeFile("temp/generatedTest.lua2p", [[ n = !(0b101) ]])
		runCommandToFail(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])
		runCommand      (luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --jitsyntax]])
		assertCodeOutput(readFile"temp/generatedTest.lua", [[n = 5]])
	end

	--linenumbers
	writeFile("temp/generatedTest.lua2p", [[
		x = 1
		y = 2
	]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])               ; assertCodeOutput(readFile"temp/generatedTest.lua", "x = 1\n\t\ty = 2")
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --linenumbers]]) ; assertCodeOutput(readFile"temp/generatedTest.lua", "--[[@1]]x = 1\n\t\t--[[@2]]y = 2")

	--loglevel
	writeFile("temp/generatedTest.lua2p", [[ @@LOG("warning", "Uh oh!") ]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --loglevel=error]])   ; assertCodeOutput(readFile"temp/generatedTest.lua", [[]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --loglevel=warning]]) ; assertCodeOutput(readFile"temp/generatedTest.lua", [[print("Uh oh!")]])

	--macroprefix/macrosuffix
	writeFile("temp/generatedTest.lua2p", [[ !(local function m_foo()end) @@foo() ]]) ; runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --macroprefix=m_]])
	writeFile("temp/generatedTest.lua2p", [[ !(local function foo_m()end) @@foo() ]]) ; runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --macrosuffix=_m]])

	--meta
	do
		writeFile("temp/generatedTest.lua2p", [[ !tostring"" ]])
		removeFile("temp/generatedTest.meta.lua")
		runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --meta]])
		assert(not fileExists("temp/generatedTest.meta.lua"))

		writeFile("temp/generatedTest.lua2p", [[ !bad ]])
		removeFile("temp/generatedTest.meta.lua")
		runCommandToFail(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --meta]])
		assert(fileExists("temp/generatedTest.meta.lua"))

		writeFile("temp/generatedTest.lua2p", [[ !bad ]])
		removeFile("temp/generatedTest.metafoo")
		runCommandToFail(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --meta=temp/generatedTest.metafoo]])
		assert(fileExists("temp/generatedTest.metafoo"))
	end

	--nonil
	writeFile("temp/generatedTest.lua2p", [[ v = !(nil) ]])
	runCommand      (luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])
	runCommandToFail(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --nonil]])

	--novalidate
	writeFile("temp/generatedTest.lua2p", [[ bad ]])
	runCommand      (luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --novalidate]])
	runCommandToFail(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])

	--outputextension
	writeFile("temp/generatedTest.lua2p", [[]])
	removeFile("temp/generatedTest.lua") ; runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])                       ; assert(fileExists("temp/generatedTest.lua"))
	removeFile("temp/generatedTest.foo") ; runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --outputextension=foo]]) ; assert(fileExists("temp/generatedTest.foo"))
	runCommandToFail(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --outputextension=lua2p]]) -- Same resulting output path as the input path.

	--outputpaths
	writeFile("temp/generatedTest.lua2p", [[]])
	removeFile("temp/generatedTest.foo") ; runCommand(luaExe, [[preprocess-cl.lua --outputpaths temp/generatedTest.lua2p temp/generatedTest.foo]]) ; assert(fileExists("temp/generatedTest.foo"))
	runCommandToFail(luaExe, [[preprocess-cl.lua --outputpaths temp/generatedTest.lua2p]]) -- Missing output path.
	runCommandToFail(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --outputpaths temp/generatedTest.lua]]) -- '--outputpaths' must appear before any input path.

	--release
	writeFile("temp/generatedTest.lua2p", [[ @@ASSERT(x, "Noes!") ]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])           ; assertCodeOutput(readFile"temp/generatedTest.lua", [[if not (x) then  error(("Noes!"))  end]])
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --release]]) ; assertCodeOutput(readFile"temp/generatedTest.lua", [[]])

	--saveinfo
	writeFile("temp/generatedTest.lua2p", [[]])
	removeFile("temp/info.lua")
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --saveinfo=temp/info.lua]])
	local info = requireNewTemp"temp.info"
	assert(type(info) == "table")

	--silent
	do
		writeFile("temp/generatedTest.lua2p", [[]])

		local handle = assert(io.popen(createCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p]])))
		local output = handle:read"*a"
		handle:close()
		assert(output:find("generatedTest.lua2p", 1, true)) -- Something like this should've been printed: Processing 'foo.lua2p'...

		local handle = assert(io.popen(createCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --silent]])))
		local output = handle:read"*a"
		handle:close()
		assert(output == "")
	end

	--version
	writeFile("temp/generatedTest.lua2p", [[ print("Yo.") ]])
	removeFile("temp/generatedTest.lua")
	local handle = assert(io.popen(createCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --version]])))
	local output = handle:read"*a"
	handle:close()
	assert(output:find"^%d+%.%d+%.%d+$" or output:find"^%d+%.%d+%.%d+%-%w+$") -- '1.2.3' or '1.2.3-foo'
	assert(not fileExists("temp/generatedTest.lua")) -- '--version' should prevent any processing.

	--debug (Just check that the meta file isn't removed.)
	writeFile("temp/generatedTest.lua2p", [[ !tostring"" ]])
	removeFile("temp/generatedTest.meta.lua")
	runCommand(luaExe, [[preprocess-cl.lua temp/generatedTest.lua2p --debug]])
	assert(fileExists("temp/generatedTest.meta.lua"))

	-- (Stop parsing options.)
	writeFile("--foo.lua2p", [[]]) -- Note: We're operating outside the temp folder!
	runCommandToFail(luaExe, [[preprocess-cl.lua    --foo.lua2p]]) -- Invalid option.
	runCommand      (luaExe, [[preprocess-cl.lua -- --foo.lua2p]])
	assert(fileExists("--foo.lua"))
	removeFile("--foo.lua2p")
	removeFile("--foo.lua")
end)

doTest("Messages", function()
	for cycle = 1, 2 do
		print("Cycle "..cycle)

		writeFile("temp/generatedHandler.lua",
			cycle == 1 and [[ return {
				init       = function(inPaths, outPaths  )  assert(not outPaths) ; table.insert(inPaths, "temp/generatedTest.lua2p")  end,
				insert     = function(path, name         )  assert(name == "foo()") ; return "un"..name  end,
				beforemeta = function(path, lua          )  assert(type(lua) == "string")  end,
				aftermeta  = function(path, lua          )  return "-- Hello\n"..lua  end,
				filedone   = function(path, outPath, info)  assert(outPath == "temp/generatedTest.lua") ; assert(type(info) == "table")  end,
				fileerror  = function(path, err          )  end,
				alldone    = function(                   )  end,
			}]]
			or [[ return function(message, ...)
				if     message == "init"       then  local inPaths, outPaths   = ... ; assert(not outPaths) ; table.insert(inPaths, "temp/generatedTest.lua2p")
				elseif message == "insert"     then  local path, name          = ... ; assert(name == "foo()") ; return "un"..name
				elseif message == "beforemeta" then  local path, lua           = ... ; assert(type(lua) == "string")
				elseif message == "aftermeta"  then  local path, lua           = ... ; return "-- Hello\n"..lua
				elseif message == "filedone"   then  local path, outPath, info = ... ; assert(outPath == "temp/generatedTest.lua") ; assert(type(info) == "table")
				elseif message == "fileerror"  then  local path, err           = ...
				elseif message == "alldone"    then  -- void
				else error("Unhandled message '"..tostring(message).."'") end
			end]]
		)

		writeFile("temp/generatedTest.lua2p", [[@insert"foo()"]])
		removeFile("temp/generatedTest.lua")
		runCommand(luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua]])
		assertCodeOutput(readFile"temp/generatedTest.lua", '-- Hello\nunfoo()')
	end

	-- "init"
	do
		writeFile("temp/generatedTest.lua2p", [[]])

		writeFile("temp/generatedHandler.lua", [[ return {init=function(inPaths, outPaths)  end} ]])
		runCommand(luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua --outputpaths temp/generatedTest.lua2p temp/generatedTest.lua]])

		-- Path arrays must be the same length.
		writeFile("temp/generatedHandler.lua", [[ return {init=function(inPaths, outPaths)  outPaths[1] = nil  end} ]])
		runCommandToFail(luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua --outputpaths temp/generatedTest.lua2p temp/generatedTest.lua]])

		-- Path arrays must not be empty.
		writeFile("temp/generatedHandler.lua", [[ return {init=function(inPaths, outPaths) inPaths[1] = nil ; if outPaths then outPaths[1] = nil end  end} ]])
		runCommandToFail(luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua               temp/generatedTest.lua2p]])
		runCommandToFail(luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua --outputpaths temp/generatedTest.lua2p temp/generatedTest.lua]])
	end

	-- "insert" must return a string.
	writeFile("temp/generatedTest.lua2p",  [[ n = @insert"" ]])
	writeFile("temp/generatedHandler.lua", [[ return{insert=function()return"5"end} ]]) ; runCommand      (luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua temp/generatedTest.lua2p]])
	writeFile("temp/generatedHandler.lua", [[ return{insert=function()return 5 end} ]]) ; runCommandToFail(luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua temp/generatedTest.lua2p]])

	-- "aftermeta" must return a string or nil/nothing.
	writeFile("temp/generatedTest.lua2p",  [[ whatever ]])
	writeFile("temp/generatedHandler.lua", [[ return{aftermeta=function()         end} ]]) ; runCommand      (luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua --novalidate temp/generatedTest.lua2p]])
	writeFile("temp/generatedHandler.lua", [[ return{aftermeta=function()return"5"end} ]]) ; runCommand      (luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua --novalidate temp/generatedTest.lua2p]])
	writeFile("temp/generatedHandler.lua", [[ return{aftermeta=function()return 5 end} ]]) ; runCommandToFail(luaExe, [[preprocess-cl.lua --handler=temp/generatedHandler.lua --novalidate temp/generatedTest.lua2p]])
end)



--==============================================================

local countResults = 0
local countFails   = 0

for _, result in ipairs(results) do
	if not result.label then
		countResults = countResults+1
		if not result.ok  then  countFails = countFails+1  end
	end
end

print()
print("Results:")

for _, result in ipairs(results) do
	if result.label then
		print("----- "..result.label)
	elseif result.ok then
		print("ok      "..result.description)
	else
		print("FAILED  "..result.description)
	end
end

print()
if countFails == 0 then
	print("All "..countResults.." tests passed! :)")
else
	print(countFails.."/"..countResults.." tests FAILED!!! :O")
end

os.exit(countFails == 0 and 0 or 1)
