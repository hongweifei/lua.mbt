// debug.getupvalue / setupvalue / upvalueid / upvaluejoin.

///|
/// The upvalue names of a C function are all the empty string, and its
/// values live in the builtin's upvalue array.
fn upvalue_of(f : @core.Value, n : Int) -> (String, @core.Value)? {
  match f {
    @core.VFunc(cl) => {
      let desc = cl.proto.upvals
      if n >= 1 && n <= desc.length() {
        let d = desc[n - 1]
        let name = if d.name.length() == 0 {
          "(no name)"
        } else {
          @core.text_of(d.name.data())
        }
        Some((name, cl.upvals[n - 1].get()))
      } else {
        None
      }
    }
    @core.VBuiltin(b) => {
      let ups = b.upvals
      if n >= 1 && n <= ups.length() {
        Some(("", ups[n - 1]))
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn setupvalue_of(f : @core.Value, n : Int, value : @core.Value) -> String? {
  match f {
    @core.VFunc(cl) => {
      let desc = cl.proto.upvals
      if n >= 1 && n <= desc.length() {
        let d = desc[n - 1]
        cl.upvals[n - 1].set(value)
        Some(
          if d.name.length() == 0 {
            "(no name)"
          } else {
            @core.text_of(d.name.data())
          },
        )
      } else {
        None
      }
    }
    @core.VBuiltin(b) => {
      let ups = b.upvals
      if n >= 1 && n <= ups.length() {
        ups[n - 1] = value
        Some("")
      } else {
        None
      }
    }
    _ => None
  }
}

///|
pub fn db_getupvalue(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  // The upvalue index is checked first and the closure second, as
  // `db_getupvalue` does, so a missing index is what gets reported.
  let n = @core.check_int(st, args, 2, "getupvalue")
  let f = @core.check_function(st, args, 1, "getupvalue")
  match upvalue_of(f, n.to_int()) {
    Some((name, value)) => [@core.VStr(@core.LStr::of_string(name)), value]
    // An index that is out of range answers with nothing at all, which is
    // `auxupvalue`'s `return 0` -- not with a nil.
    None => []
  }
}

///|
pub fn db_setupvalue(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  // The value is required and checked first, then the index, then the closure
  // (`db_setupvalue`: `luaL_checkany(L, 3)`, then the function).
  let value = @core.check_any(st, args, 3, "setupvalue")
  let n = @core.check_int(st, args, 2, "setupvalue")
  let f = @core.check_function(st, args, 1, "setupvalue")
  match setupvalue_of(f, n.to_int(), value) {
    Some(name) => [@core.VStr(@core.LStr::of_string(name))]
    // As in `getupvalue`, an index that is out of range answers with nothing.
    None => []
  }
}

///|
pub fn db_upvalueid(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  // Index first, closure second (`db_upvalueid`).
  let n = @core.check_int(st, args, 2, "upvalueid").to_int()
  let f = @core.check_function(st, args, 1, "upvalueid")
  match f {
    @core.VFunc(cl) =>
      if n >= 1 && n <= cl.upvals.length() {
        let cell = cl.upvals[n - 1]
        if cell.id_tag is @core.VNil {
          cell.id_tag = @core.VUserData(
            @core.LUserData::new_light(@core.UDUpvalTag(cell.id)),
          )
        }
        [cell.id_tag]
      } else {
        [@core.VNil]
      }
    // A host function holds its upvalues as plain values, and the reference
    // still answers with a tag for a slot that exists.
    @core.VBuiltin(b) =>
      if n >= 1 && n <= b.upvals.length() {
        [
          @core.VUserData(
            @core.LUserData::new_light(@core.UDCUpvalTag(b.id, n)),
          ),
        ]
      } else {
        [@core.VNil]
      }
    _ => [@core.VNil]
  }
}

///|
pub fn db_upvaluejoin(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  // Each pair is checked index first (`checkupval`), and the first pair before
  // the second.
  let n1 = @core.check_int(st, args, 2, "upvaluejoin").to_int()
  let f1 = @core.check_function(st, args, 1, "upvaluejoin")
  let n2 = @core.check_int(st, args, 4, "upvaluejoin").to_int()
  let f2 = @core.check_function(st, args, 3, "upvaluejoin")
  match (f1, f2) {
    (@core.VFunc(a), @core.VFunc(c)) => {
      if n1 < 1 || n1 > a.upvals.length() {
        @core.arg_error(st, 2, "upvaluejoin", "invalid upvalue index")
      }
      if n2 < 1 || n2 > c.upvals.length() {
        @core.arg_error(st, 4, "upvaluejoin", "invalid upvalue index")
      }
      a.upvals[n1 - 1] = c.upvals[n2 - 1]
      []
    }
    _ => @core.arg_error(st, 1, "upvaluejoin", "Lua function expected")
  }
}
