// Raw table access, metatable access, iteration and select.

///|
pub fn base_rawget(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = @core.check_table(state, args, 1, "rawget")
  let k = @core.check_any(state, args, 2, "rawget")
  @core.One(t.get(k))
}

///|
pub fn base_rawset(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = @core.check_table(state, args, 1, "rawset")
  let k = @core.check_any(state, args, 2, "rawset")
  let v = @core.check_any(state, args, 3, "rawset")
  if !t.set(k, v) {
    @vm.invalid_key_error(state, k)
  }
  @core.One(t.as_value())
}

///|
pub fn base_rawequal(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let a = @core.check_any(state, args, 1, "rawequal")
  let b = @core.check_any(state, args, 2, "rawequal")
  @core.One(@core.VBool(a.raw_equal(b)))
}

///|
pub fn base_rawlen(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  // The message names the value's own type, and a missing argument reports
  // "no value" -- `luaL_typeerror`'s shape, which `check_any` cannot give.
  if args.length() < 1 {
    @core.arg_error(
      state, 1, "rawlen", "table or string expected, got no value",
    )
  }
  let v = args[0]
  match v {
    @core.VTable(t) => @core.One(@core.VInt(t.raw_len()))
    @core.VStr(s) => @core.One(@core.VInt(s.length().to_int64()))
    _ =>
      @core.arg_error(
        state,
        1,
        "rawlen",
        "table or string expected, got " + @core.type_error_name(state, v),
      )
  }
}

///|
pub fn base_getmetatable(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_any(state, args, 1, "getmetatable")
  match @vm.metatable_of(state, v) {
    Some(mt) =>
      match mt.get_str("__metatable") {
        @core.VNil => @core.One(@core.VTable(mt))
        hidden => @core.One(hidden)
      }
    None => @core.One(@core.VNil)
  }
}

///|
/// Sets the metatable of a table.  Only tables accept one from Lua code.
pub fn base_setmetatable(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = @core.check_table(state, args, 1, "setmetatable")
  // The metatable must be given: `luaL_argexpected` reports a missing second
  // argument the same way it reports a wrong one.
  let mt = if args.length() < 2 {
    @core.arg_error(
      state, 2, "setmetatable", "nil or table expected, got no value",
    )
  } else {
    args[1]
  }
  match mt {
    @core.VNil => ()
    @core.VTable(_) => ()
    _ =>
      @core.arg_error(
        state,
        2,
        "setmetatable",
        "nil or table expected, got " + @core.type_error_name(state, mt),
      )
  }
  match t.meta {
    Some(old) =>
      if !old.get_str("__metatable").is_nil() {
        @core.runtime_error(state, "cannot change a protected metatable")
      }
    None => ()
  }
  match mt {
    @core.VTable(m) => t.set_metatable(Some(m))
    _ => t.set_metatable(None)
  }
  // A metatable with a `__mode` or a `__gc` is what makes the collector look at
  // this table every cycle.
  @core.gc_register(state, @core.VTable(t))
  @core.One(@core.VTable(t))
}

///|
pub fn base_next(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = @core.check_table(state, args, 1, "next")
  let k = if args.length() < 2 { @core.VNil } else { args[1] }
  match t.next(k) {
    @core.NextPair(k2, v2) => @core.Two(k2, v2)
    @core.NextEnd => @core.One(@core.VNil)
    @core.NextBadKey => @core.vm_error(state, "invalid key to 'next'")
  }
}

///|
/// `pairs` honours `__pairs` and otherwise returns the `next` primitive.
pub fn base_pairs(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_any(state, args, 1, "pairs")
  let h = @vm.metafield(state, v, "__pairs")
  if !h.is_nil() {
    let res = @vm.call_metamethod(state, h, [v], 3, "")
    while res.length() < 3 {
      res.push(@core.VNil)
    }
    return @core.Many(res)
  }
  // No type check here: `pairs(1)` is a valid call that returns the `next`
  // triple, and the failure comes when the iterator runs (`luaB_pairs` only
  // checks that an argument was given).
  @core.Many([next_builtin(state), v, @core.VNil])
}

///|
/// The iterator returned by `ipairs`.
pub fn ipairs_iterator(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = @core.check_any(state, args, 1, "ipairs")
  let i = @core.check_int(state, args, 2, "ipairs")
  let next_i = i + 1L
  let v = @vm.index_get(state, t, @core.VInt(next_i), -1)
  if v.is_nil() {
    @core.One(@core.VNil)
  } else {
    @core.Two(@core.VInt(next_i), v)
  }
}

///|
/// `ipairs` respects `__index`, as the reference implementation does.
pub fn base_ipairs(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_any(state, args, 1, "ipairs")
  @core.Many([ipairs_builtin(state), v, @core.VInt(0L)])
}

///|
pub fn base_select(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  if args.length() == 0 {
    @core.arg_error(state, 1, "select", "number expected, got no value")
  }
  let n = args.length() - 1
  match args[0] {
    @core.VStr(s) =>
      if @core.text_of(s.data()) == "#" {
        @core.One(@core.VInt(n.to_int64()))
      } else {
        select_from(state, @core.check_int(state, args, 1, "select"), n, args)
      }
    _ => select_from(state, @core.check_int(state, args, 1, "select"), n, args)
  }
}

///|
pub fn select_from(
  state : @core.LuaState,
  i : Int64,
  n : Int,
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let mut idx = i
  if idx < 0L {
    idx = n.to_int64() + idx + 1L
    if idx < 1L {
      @core.arg_error(state, 1, "select", "index out of range")
    }
  } else if idx == 0L {
    @core.arg_error(state, 1, "select", "index out of range")
  }
  let out : Array[@core.Value] = []
  let mut j = idx.to_int()
  while j <= n {
    out.push(args[j])
    j = j + 1
  }
  @core.Many(out)
}
