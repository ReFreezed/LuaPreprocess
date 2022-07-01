rockspec_format = "3.0"

package = "LuaPreprocess"
version = "1.20.0-1"
source  = {url="git-ssh://git@github.com:ReFreezed/LuaPreprocess.git", branch="master", tag="1.20.0"}

description = {
	summary  = "A small and straightforward Lua preprocessor with simple syntax.",
	detailed = [[
		LuaPreprocess is a small and straightforward Lua preprocessor
		featuring simple syntax. Write embedded metaprograms to generate code
		using normal Lua inside your Lua files.
	]],

	license    = "MIT",
	homepage   = "http://refreezed.com/luapreprocess/",
	issues_url = "https://github.com/ReFreezed/LuaPreprocess/issues",

	labels = {
		"buildsystem",
		"commandline",
		"metaprogram",
		"preprocessing",
		"purelua",
	},
}
dependencies = {
	"lua >= 5.1, < 5.5",
}
build = {
	type    = "builtin",
	modules = {
		preprocess        = "preprocess.lua",
		["preprocess-cl"] = "preprocess-cl.lua",
	},
}
