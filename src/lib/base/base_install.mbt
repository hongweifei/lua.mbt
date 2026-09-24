// Installing the basic library.

///|
pub fn open_base_library(state : @core.LuaState) -> Unit {
  let g = state.globals
  g.set_str(
    "print",
    @core.VBuiltin(@core.LBuiltin::make("print", -1, base_print)),
  )
  g.set_str("type", @core.VBuiltin(@core.LBuiltin::make("type", 1, base_type)))
  g.set_str(
    "tostring",
    @core.VBuiltin(@core.LBuiltin::make("tostring", 1, base_tostring)),
  )
  g.set_str(
    "tonumber",
    @core.VBuiltin(@core.LBuiltin::make("tonumber", 2, base_tonumber)),
  )
  g.set_str(
    "rawget",
    @core.VBuiltin(@core.LBuiltin::make("rawget", 2, base_rawget)),
  )
  g.set_str(
    "rawset",
    @core.VBuiltin(@core.LBuiltin::make("rawset", 3, base_rawset)),
  )
  g.set_str(
    "rawequal",
    @core.VBuiltin(@core.LBuiltin::make("rawequal", 2, base_rawequal)),
  )
  g.set_str(
    "rawlen",
    @core.VBuiltin(@core.LBuiltin::make("rawlen", 1, base_rawlen)),
  )
  g.set_str(
    "getmetatable",
    @core.VBuiltin(@core.LBuiltin::make("getmetatable", 1, base_getmetatable)),
  )
  g.set_str(
    "setmetatable",
    @core.VBuiltin(@core.LBuiltin::make("setmetatable", 2, base_setmetatable)),
  )
  g.set_str("next", @core.VBuiltin(@core.LBuiltin::make("next", 2, base_next)))
  g.set_str(
    "pairs",
    @core.VBuiltin(
      @core.LBuiltin::make_kind("pairs", @core.BK_PAIRS, 1, base_pairs),
    ),
  )
  g.set_str(
    "ipairs",
    @core.VBuiltin(@core.LBuiltin::make("ipairs", 1, base_ipairs)),
  )
  g.set_str(
    "select",
    @core.VBuiltin(@core.LBuiltin::make("select", -1, base_select)),
  )
  g.set_str(
    "error",
    @core.VBuiltin(@core.LBuiltin::make("error", 2, base_error)),
  )
  g.set_str(
    "assert",
    @core.VBuiltin(@core.LBuiltin::make("assert", -1, base_assert)),
  )
  g.set_str(
    "pcall",
    @core.VBuiltin(
      @core.LBuiltin::make_kind("pcall", @core.BK_PCALL, -1, base_pcall),
    ),
  )
  g.set_str(
    "xpcall",
    @core.VBuiltin(
      @core.LBuiltin::make_kind("xpcall", @core.BK_XPCALL, -1, base_xpcall),
    ),
  )
  g.set_str(
    "load",
    @core.VBuiltin(@core.LBuiltin::make("load", 4, @load.base_load)),
  )
  g.set_str(
    "loadfile",
    @core.VBuiltin(@core.LBuiltin::make("loadfile", 3, @load.base_loadfile)),
  )
  g.set_str(
    "dofile",
    @core.VBuiltin(@core.LBuiltin::make("dofile", 1, @load.base_dofile)),
  )
  g.set_str(
    "collectgarbage",
    @core.VBuiltin(
      @core.LBuiltin::make("collectgarbage", 2, base_collectgarbage),
    ),
  )
  g.set_str("warn", @core.VBuiltin(@core.LBuiltin::make("warn", -1, base_warn)))
  g.set_str(
    "require",
    @core.VBuiltin(@core.LBuiltin::make("require", 1, @load.base_require)),
  )
  g.set_str("_G", @core.VTable(g))
  g.set_str("_VERSION", @core.VStr(@core.LStr::of_string("Lua 5.4")))
}

///|
/// The `next` primitive, exposed so that `pairs` can return it.
pub fn next_builtin(st : @core.LuaState) -> @core.Value {
  st.globals.get_str("next")
}

///|
/// A cached `ipairs` iterator.
pub fn ipairs_builtin(st : @core.LuaState) -> @core.Value {
  match st.registry.get_str("__ipairs_iter") {
    @core.VBuiltin(_) => st.registry.get_str("__ipairs_iter")
    _ => {
      let b = @core.VBuiltin(
        @core.LBuiltin::make("ipairs_iterator", 2, ipairs_iterator),
      )
      st.registry.set_str("__ipairs_iter", b)
      b
    }
  }
}
