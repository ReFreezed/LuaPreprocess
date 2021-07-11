--==============================================================
--= Test suite for LuaPreprocess
--==============================================================

io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

local ppChunk = assert(loadfile"preprocess.lua")
local results = {}

local function doTest(description, f, ...)
	print("Running test: "..description)

	local ok, err = pcall(f, ...)
	if not ok then  print("Error: "..tostring(err))  end

	table.insert(results, {description=description, ok=ok})
end
local function addLabel(label)
	table.insert(results, {label=label})
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readFile(path)
	local file, err = io.open(path, "rb")
	if not file then  return nil, err  end

	local data = file:read("*a")
	file:close()

	return data
end
local function writeFile(path, data)
	local file, err = io.open(path, "wb")
	if not file then  return false, err  end

	file:write(data)
	file:close()

	return true
end

local function assertCodeOutput(codeOut, codeExpected, message)
	if trim(codeOut) ~= codeExpected then
		error(message or "Unexpected output: "..codeOut, 2)
	end
end
local function assertCmd(cmd)
	local code = os.execute(cmd)
	if code ~= 0 then  error("Command failed: "..cmd, 2)  end
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
	local luaIn = [[
		!(
		outputLua("local s = ")
		outputValue("\n")
		)
	]]

	local luaOut = assert(pp.processString{ code=luaIn })
	assertCodeOutput(luaOut, [[local s = "\n"]])
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
	assertCodeOutput(luaOut, [[local z = 137]])
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
	assertCodeOutput(luaOut, [[local n, s = 3125, "foobar";]])
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

	-- Code blocks in macros.
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !(  1 ) )                ]]}), [[n = 1]]            )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !!("1") )                ]]}), [[n = 1]]            )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !(  1 ) }                ]]}), [[n = { 1 }]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !!("1") }                ]]}), [[n = { 1 }]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !(  1 ) + 2 )            ]]}), [[n = 1 + 2]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !!("1") + 2 )            ]]}), [[n = 1 + 2]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !(  1 ) + 2 }            ]]}), [[n = { 1 + 2 }]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !!("1") + 2 }            ]]}), [[n = { 1 + 2 }]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( 1 + !(  2 ) )            ]]}), [[n = 1 + 2]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( 1 + !!("2") )            ]]}), [[n = 1 + 2]]        )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ 1 + !(  2 ) }            ]]}), [[n = { 1 + 2 }]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ 1 + !!("2") }            ]]}), [[n = { 1 + 2 }]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( 1 + !(  2 ) + 3 )        ]]}), [[n = 1 + 2 + 3]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( 1 + !!("2") + 3 )        ]]}), [[n = 1 + 2 + 3]]    )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ 1 + !(  2 ) + 3 }        ]]}), [[n = { 1 + 2 + 3 }]])
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ 1 + !!("2") + 3 }        ]]}), [[n = { 1 + 2 + 3 }]])
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO( !!("1")!!("+")!!("2") )  ]]}), [[n = 1+2]]          )
	assertCodeOutput(assert(pp.processString{ code=[[  !(function ECHO(v) return v end)  n = @@ECHO{ !!("1")!!("+")!!("2") }  ]]}), [[n = { 1+2 }]]      )

	-- Invalid: Ambiguous syntax.
	assert(not pp.processString{ code=[[
		!function VOID()  return ""  end
		v = @@VOID
		() 1
	]]})

	-- Invalid: Bad macro arguments format.
	assert(not pp.processString{ code=[[ @insert type[]   ]]})
	assert(not pp.processString{ code=[[ @insert type + 1 ]]})

	-- Invalid: Non-expression code block in macro.
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO(!(do end))  ]]})
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO{!(do end)}  ]]})
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO(!(      ))  ]]})
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO{!(      )}  ]]})
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO(!!(     ))  ]]})
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO{!!(     )}  ]]})

	-- Invalid: Invalid value from code block in macro.
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO(!!(1))  ]]})

	-- Invalid: Nested code block in macro.
	assert(not pp.processString{ code=[[  !(function ECHO(v) return v end)  v = @@ECHO( !!( !(1) ) )  ]]})
end)



addLabel("Library API")

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



addLabel("Command line")

doTest("Simple processing of single file", function()
	assert(writeFile("local/generatedTest.lua2p", [[
		!outputLua("math.floor(1.5)")
	]]))
	assertCmd([[lua ./preprocess-cl.lua local/generatedTest.lua2p]])

	local luaOut = assert(readFile("local/generatedTest.lua"))
	assertCodeOutput(luaOut, [[math.floor(1.5)]])
end)

doTest("Send data", function()
	assert(writeFile("local/generatedTest.lua2p", [[
		print(!(dataFromCommandLine))
	]]))
	assertCmd([[lua ./preprocess-cl.lua --outputpaths --data="Hello, world!" local/generatedTest.lua2p local/generatedTest.lua]])

	local luaOut = assert(readFile("local/generatedTest.lua"))
	assertCodeOutput(luaOut, [[print("Hello, world!")]])
end)

doTest("Handler + multiple files", function()
	assert(writeFile("local/generatedHandler.lua", [[
		_G.one = 1
		return {
			aftermeta = function(path, luaString)
				print(path, luaString)
				return 'print("foo");'..luaString -- Prepend some code.
			end,
		}
	]]))
	assert(writeFile("local/generatedTest1.lua2p", "!!local x = one+2*3\n"))
	assert(writeFile("local/generatedTest2.lua2p", "!!local y = one+2^10\n"))

	assertCmd([[lua ./preprocess-cl.lua --handler=local/generatedHandler.lua local/generatedTest1.lua2p local/generatedTest2.lua2p]])

	local luaOut = assert(readFile("local/generatedTest1.lua"))
	assertCodeOutput(luaOut, [[print("foo");local x = 7]])
	local luaOut = assert(readFile("local/generatedTest2.lua"))
	assertCodeOutput(luaOut, [[print("foo");local y = 1025]])
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
