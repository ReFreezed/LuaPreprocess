--[[
	Blah.
]]
-- Preprocessor line.

local a = "a" -- Comment A.
print(a)

-- More preprocessor lines.

a = a.."b"..a -- Comment, string concat.

print("Aaaaand...")
print(2)

print("Aaaaand...")
print(4)

print("Aaaaand...")
print(6)



local c   = 115
local str = "Included string #64.\nargs[1] is what"

_G.global3 = 99



-- Extended preprocessor line. (Balanced brackets.)

local z = 137



-- Dual code. (Outputs both both preprocessor code and normal Lua. Can only be used for assignment statements.)
local alpha    = "[%a_]"
local alphanum = "[%a%d_]"
local num      = "%d"
local ident    = "[%a_][%a%d_]*"
local funcCall = "[%a_][%a%d_]*%(.-%)"

local s = [[:: 2 * hello5( foo ){ ... }]]
print(s:match(ident))    -- "hello5"
print(s:match(num))      -- "2"
print(s:match(funcCall)) -- "hello5( foo )"



-- File inserts.

local uhh = 7
print("Final program - uhh: "..uhh)



-- Macros.

print("Blargh!")

print(string.format('We are at %s:%d!', "misc/quickTest.lua2p", 87))

local ok = 1==1

if not (ok) then error("Oh "..tonumber("7",10).." noes!") end

local s = "foo"
local t = { 496, b=true } -- @@func() means the same as @insert func().

local f = function(a, b)
	while true do
		repeat until arePlanetsAligned("mars", "jupiter")
		break
	end
	return "", nil
end



-- Misc.
print("dataFromCommandLine: Hello, world!")
print("The end.")
