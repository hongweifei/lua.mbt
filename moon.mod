// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "hongweifei/lua"

version = "0.1.0"

readme = "README.md"

license = "Apache-2.0"

keywords = [ "lua", "interpreter", "vm", "script" ]

description = "A complete Lua 5.4 interpreter written in MoonBit"

preferred_target = "native"

import {
  "moonbitlang/async@0.22.1",
}
