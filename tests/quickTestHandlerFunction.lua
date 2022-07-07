--[[============================================================
--=
--=  Test message handler
--=  for use with preprocess-cl.lua
--=
--=  Alternative #2: A single catch-all message handler.
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

return function(message, ...)
	if message == "beforemeta" then
		local path, luaString = ...
		print("... Now running metaprogram for "..path)

	elseif message == "aftermeta" then
		local path, luaString = ...

		-- Remove comments (quick and dirty).
		luaString = luaString
			:gsub("%-%-%[%[.-%]%]", "") -- Multi-line.
			:gsub("%-%-[^\n]*",     "") -- Single line.

		return luaString

	elseif message == "filedone" then
		local path, outputPath = ...
		print("... Done with "..path.." (writing to "..outputPath..")")
	end
end
