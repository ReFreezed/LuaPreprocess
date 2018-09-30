# LuaPreprocess

<!-- ![version 1.0](https://img.shields.io/badge/version-1.0-green.svg) -->

A small and straightforward Lua preprocessor featuring a simple syntax.
Write embedded metaprograms to generate code using normal Lua inside your Lua files.

*LuaPreprocess* is written in pure Lua 5.1. It's a single file with no external dependencies. [MIT license](LICENSE.txt).

- [Example Program](#example-program)
- [Usage](#usage)



## Example Program
```lua
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
```



## Usage
First you of course need [Lua 5.1](https://www.lua.org/versions.html#5.1) installed on your system. (Binaries can be
downloaded from [LuaBinaries via SourceForge](https://sourceforge.net/projects/luabinaries/files/5.1.5/Tools%20Executables/)
if you don't want to compile Lua from source. For Windows I can also recommend installing
[LuaForWindows](https://github.com/rjpcomputing/luaforwindows).)

How to preprocess your Lua files from the command line:

#### Windows
```batch
Preprocess.cmd filepath1 [filepath2 ...]
```

#### Any System
```batch
lua main.lua filepath1 [filepath2 ...]
```

If a filepath is, for example, `C:/MyApp/app.lua2p` then *LuaPreprocess* will write the processed file to `C:/MyApp/app.lua`.


