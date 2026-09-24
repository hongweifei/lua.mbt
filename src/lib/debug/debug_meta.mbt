// debug.getmetatable / setmetatable / getregistry / getuservalue /
// setuservalue.

///|
// The builtin callback type demands a `raise`; this function never uses it.
#warnings("-unused_error_type")
pub fn db_getregistry(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  _args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  [@core.VTable(st.registry)]
}

///|
pub fn db_getmetatable(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  if args.length() < 1 {
    @core.arg_error(st, 1, "getmetatable", "value expected")
  }
  match @vm.metatable_of(st, args[0]) {
    Some(mt) =>
      // The reference hides a metatable whose __metatable field is set.
      match mt.get_str("__metatable") {
        @core.VNil => [@core.VTable(mt)]
        v => [v]
      }
    None => [@core.VNil]
  }
}

///|
pub fn db_setmetatable(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  // The metatable is what is checked, and the check names the second argument
  // whether it is missing or of the wrong type (`luaL_argexpected`); the value
  // itself is not checked at all.
  let v = if args.length() >= 1 { args[0] } else { @core.VNil }
  let mt : @core.LTable? = if args.length() < 2 {
    @core.arg_error(
      st, 2, "setmetatable", "nil or table expected, got no value",
    )
  } else {
    match args[1] {
      @core.VNil => None
      @core.VTable(t) => Some(t)
      _ =>
        @core.arg_error(
          st,
          2,
          "setmetatable",
          "nil or table expected, got " + @core.type_error_name(st, args[1]),
        )
    }
  }
  match v {
    @core.VTable(t) => t.meta = mt
    @core.VUserData(u) => u.meta = mt
    _ =>
      // Values without a metatable slot keep it in the registry, keyed by
      // type name, exactly like the base `setmetatable` does.
      match mt {
        Some(t) => st.registry.set_str("__mt_" + v.type_name(), @core.VTable(t))
        None => st.registry.set_str("__mt_" + v.type_name(), @core.VNil)
      }
  }
  [v]
}

///|
/// `debug.getuservalue` reports the user value a userdata holds at an index and
/// says whether there was one at all; anything that is not a full userdata has
/// none, which is what `luaL_pushfail` answers.
pub fn db_getuservalue(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let which = @core.opt_int(st, args, 2, "getuservalue", 1L).to_int() - 1
  match arg_or_nil(args, 1) {
    @core.VUserData(u) =>
      if !u.light && which >= 0 && which < u.uservalues.length() {
        [u.uservalues[which], @core.VBool(true)]
      } else {
        [@core.VNil]
      }
    _ => [@core.VNil]
  }
}

///|
/// Only a full userdata has the slots this writes to, and the value argument is
/// required even when it is nil.
pub fn db_setuservalue(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  // `db_setuservalue` checks the value (arg 3) optionally, then the userdata,
  // then the new value -- so a missing userdata reports "no value" and a
  // missing value is only reached when there is a userdata to set it on.
  let which = @core.opt_int(st, args, 3, "setuservalue", 1L).to_int() - 1
  let v = @core.check_present(st, args, 1, "setuservalue", "userdata")
  match v {
    @core.VUserData(u) => {
      if u.light {
        @core.arg_error(
          st,
          1,
          "setuservalue",
          "userdata expected, got " + @core.type_error_name(st, v),
        )
      }
      let value = @core.check_any(st, args, 2, "setuservalue")
      if which >= 0 && which < u.uservalues.length() {
        u.uservalues[which] = value
        [@core.VBool(true)]
      } else {
        [@core.VNil]
      }
    }
    _ =>
      @core.arg_error(
        st,
        1,
        "setuservalue",
        "userdata expected, got " + @core.type_error_name(st, v),
      )
  }
}
