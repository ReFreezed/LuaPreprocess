-- [[ Alternative #1: Multiple specific message handlers.
return {
	beforemeta = function(path)
		print("... Now processing "..path)
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
--]]

--[[ Alternative #2: A single catch-all message handler.
return function(message, ...)
	if message == "beforemeta" then
		local path = ...
		print("... Now processing "..path)

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
--]]
