# Examples

`*.lua2p` files are the unprocessed source files.
`*.output.lua` files show the processed output / final program.

| File | Description
| ---- | -----------
| [dualCode.lua2p](dualCode.lua2p)                             | Shows how you can declare variables in the metaprogram and final program at the same time. (`!!x=y`)
| [macros.lua2p](macros.lua2p)                                 | Shows how macros can be used to enhance code. (`@insert func()`)
| [namedConstants.lua2p](namedConstants.lua2p)                 | Shows how you can use variables in the metaprogram to output literals into the final program. (`!()`)
| [optimizeDataAccess.lua2p](optimizeDataAccess.lua2p)         | Shows how you could make data access in the final program more efficient.
| [parseFile.lua2p](parseFile.lua2p)                           | Shows how you can perform a computationally expensive operation at build time instead of every time at runtime.
| [selectiveFunctionality.lua2p](selectiveFunctionality.lua2p) | Shows how parts of the code can be excluded from the final program using variables in the metaprogram.
