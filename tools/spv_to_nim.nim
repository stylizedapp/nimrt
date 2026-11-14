import std/[os, strutils, strformat]

proc convert(spvPath, nimName: string): string =
  let data = readFile(spvPath)
  let count = data.len div 4
  result = &"const {nimName}*: array[{count}, uint32] = [\n"
  for i in 0 ..< count:
    let u = cast[ptr uint32](unsafeAddr data[i * 4])[]
    if i mod 8 == 0:
      result.add("  ")
    result.add(&"0x{u:08X}'u32, ")
    if i mod 8 == 7 or i == count - 1:
      result.add("\n")
  result.add("]\n")

let vertNim = convert("tools/shaders/ui.vert.spv", "uiVertexShaderSpv")
let fragNim = convert("tools/shaders/ui.frag.spv", "uiFragmentShaderSpv")

let fullCode = "## Generated SPIR-V Shaders for nimui\n\n" & vertNim & "\n" & fragNim
writeFile("src/nimui/gpu/shaders.nim", fullCode)
echo "Successfully updated src/nimui/gpu/shaders.nim!"
