--[[============================================================
--=
--=  Test message handler
--=  for use with preprocess-cl.lua
--=
--=  Alternative #1: Multiple specific message handlers
--=
--============================================================]]

--
-- This module shares environment with the processed files,
-- making it a good place to put things all files use/share.
--

_G.IS_DEVELOPER = true

math.tau = 2*math.pi

function _G.flipTable(t)
	local flipped = {}
	for k, v in pairs(t) do
		flipped[v] = k
	end
	return flipped
end

--
-- The module is expected to return one or multiple message handlers.
--

return {
	beforemeta = function(path, luaString)
		print("... Now running metaprogram for "..path)
	end,

	aftermeta = function(path, luaString)
		-- Remove comments (quick and dirty).
		luaString = luaString
			:gsub("%-%-%[%[.-%]%]", "") -- Multi-line.
			:gsub("%-%-[^\n]*",     "") -- Single line.

		return luaString
	end,

	filedone = function(path, outputPath)
		print("... Done with "..path.." (writing to "..outputPath..")")
	end,
}
