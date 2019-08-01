--==============================================================
--= Tests for LuaPreprocess.
--==============================================================

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

local function assertCodeOutput(codeOut, codeExpected, message)
	assert(trim(codeOut) == codeExpected, (message or "Unexpected output: "..codeOut))
end

--==============================================================



addLabel("Preprocessor code.")

doTest("Inline block with simple expression.", function()
	local pp = assert(loadfile"preprocess.lua")()
	local luaIn = [[
		local x = !(1+2*3)
	]]

	local luaOut = assert(pp.processString{ code=luaIn })
	assertCodeOutput(luaOut, [[local x = 7]])
end)

doTest("Static branch.", function()
	local pp = assert(loadfile"preprocess.lua")()
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

doTest("Output value from metaprogram.", function()
	local pp = assert(loadfile"preprocess.lua")()
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

doTest("Generate code.", function()
	local pp = assert(loadfile"preprocess.lua")()
	local luaIn = [[
		!(
		outputLua("local s = ")
		outputValue("\n")
		)
	]]

	local luaOut = assert(pp.processString{ code=luaIn })
	assertCodeOutput(luaOut, ("local s = %q"):format("\n"))

	local luaOut = assert(pp.processString{ code=luaIn, debug=true })
	assertCodeOutput(luaOut, [[local s = "\n"]]) -- Debug mode changes how newlines appear in string values.
end)

doTest("Parsing extended preprocessor line.", function()
	local pp = assert(loadfile"preprocess.lua")()
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

doTest("Dual code.", function()
	local pp = assert(loadfile"preprocess.lua")()
	local luaIn = [[
		!local  one = 1
		!local  two = 2
		!!local sum = one+two -- The expression is evaluated in the metaprogram.
	]]

	local luaOut = assert(pp.processString{ code=luaIn })
	assertCodeOutput(luaOut, [[local sum = 3]])
end)

doTest("Expression or not?", function()
	local pp = assert(loadfile"preprocess.lua")()

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

doTest("Output values of different types.", function()
	local pp = assert(loadfile"preprocess.lua")()

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

	local luaOut = pp.processString{ code=[[ func = !(function()end) ]]}
	assert(not luaOut)

	local luaOut = pp.processString{ code=[[ file = !(io.stdout) ]]}
	assert(not luaOut)

	local luaOut = pp.processString{ code=[[ co = !(coroutine.create(function()end)) ]]}
	assert(not luaOut)
end)



addLabel("Library API.")

doTest("Get useful tokens.", function()
	local pp     = assert(loadfile"preprocess.lua")()
	local tokens = pp.tokenize[[local x = 5 -- Foo!]]

	pp.removeUselessTokens(tokens)

	assert(#tokens == 4, "Unexpected amount of tokens.")
	assert(tokens[1].type  == "keyword",     "Unexpected token type 1.")
	assert(tokens[1].value == "local",       "Unexpected token value 1.")
	assert(tokens[2].type  == "identifier",  "Unexpected token type 2.")
	assert(tokens[2].value == "x",           "Unexpected token value 2.")
	assert(tokens[3].type  == "punctuation", "Unexpected token type 3.")
	assert(tokens[3].value == "=",           "Unexpected token value 3.")
	assert(tokens[4].type  == "number",      "Unexpected token type 4.")
	assert(tokens[4].value == 5,             "Unexpected token value 4.")
end)

doTest("Serialize.", function()
	local pp = assert(loadfile"preprocess.lua")()

	local t = {
		z = 99,
		a = 2,
	}

	local luaOut = assert(pp.toLua(t))
	assertCodeOutput(luaOut, [[{a=2,z=99}]]) -- Note: Table keys should be sorted.
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
		print("------ "..result.label)
	elseif result.ok then
		print("ok      "..result.description)
	else
		print("FAILED  "..result.description)
	end
end

print()
if countFails == 0 then
	print("All "..countResults.." tests passed!")
else
	print(countFails.."/"..countResults.." tests FAILED!!!")
end
