// The table library.

///|
/// Integer extremes, spelled out because the prelude has no named constants.
let max_i : Int64 = 9223372036854775807L

///|
let min_i : Int64 = -9223372036854775807L - 1L

///|
/// Whether the metatable of `v` raw-defines the field `name`.
fn mt_has(st : @core.LuaState, v : @core.Value, name : String) -> Bool {
  match @vm.metatable_of(st, v) {
    None => false
    Some(mt) => !mt.hash_get(@core.KStr(@core.LStr::of_string(name))).is_nil()
  }
}

///|
/// Checks that an argument either is a table or can behave like one, that is,
/// carries a metatable with the metamethods the operation needs.
fn checktab(
  state : @core.LuaState,
  args : ArrayView[@core.Value],
  n : Int,
  fname : String,
  index_of~ : Bool,
  newindex_of~ : Bool,
  length_of~ : Bool,
) -> @core.Value raise @core.LuaRaised {
  // A missing argument is reported as a missing table, not as a missing value
  // (`luaL_checktype`'s message names the type it wanted).
  let v = @core.check_present(state, args, n, fname, "table")
  match v {
    @core.VTable(_) => v
    _ => {
      let has_read = !index_of || mt_has(state, v, "__index")
      let has_write = !newindex_of || mt_has(state, v, "__newindex")
      let has_len = !length_of || mt_has(state, v, "__len")
      if has_read && has_write && has_len {
        v
      } else {
        @core.arg_error(
          state,
          n,
          fname,
          "table expected, got " + @core.type_error_name(state, v),
        )
      }
    }
  }
}

///|
/// `lua_tointegerx`: an integer, a float with an exact integer value, or a
/// numeral spelled out in a string.
fn to_integer(v : @core.Value) -> Int64? {
  match v {
    @core.VInt(i) => Some(i)
    @core.VNum(d) =>
      if @core.float_is_int64(d) {
        Some(@core.float_to_int64(d))
      } else {
        None
      }
    @core.VStr(s) =>
      match @core.lua_str2num(s.data()) {
        Some(@core.NInt(i)) => Some(i)
        Some(@core.NFloat(d)) =>
          if @core.float_is_int64(d) {
            Some(@core.float_to_int64(d))
          } else {
            None
          }
        None => None
      }
    _ => None
  }
}

///|
/// `luaL_len`: the length of an object, which has to be representable as an
/// integer.
fn objlen(
  state : @core.LuaState,
  v : @core.Value,
) -> Int64 raise @core.LuaRaised {
  match to_integer(@vm.len(state, v)) {
    Some(i) => i
    None => @core.runtime_error(state, "object length is not an integer")
  }
}

///|
/// `lua_geti` for a host loop: indexing that consults metamethods.
fn geti(
  state : @core.LuaState,
  t : @core.Value,
  k : Int64,
) -> @core.Value raise @core.LuaRaised {
  @vm.index_get(state, t, @core.VInt(k), @core.src_none)
}

///|
/// `lua_seti` for a host loop.
fn seti(
  state : @core.LuaState,
  t : @core.Value,
  k : Int64,
  v : @core.Value,
) -> Unit raise @core.LuaRaised {
  @vm.index_set(state, t, @core.VInt(k), v, @core.src_none)
}

///|
pub fn tbl_concat(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = checktab(
    state,
    args,
    1,
    "concat",
    index_of=true,
    newindex_of=false,
    length_of=true,
  )
  let sep = if args.length() >= 2 && !args[1].is_nil() {
    @core.check_str(state, args, 2, "concat").data()
  } else {
    Bytes::new(0)
  }
  let i = @core.opt_int(state, args, 3, "concat", 1L)
  let last = if args.length() >= 4 && !args[3].is_nil() {
    @core.check_int(state, args, 4, "concat")
  } else {
    objlen(state, t)
  }
  let buf = Buffer::Buffer(size_hint=32)
  // As in `tconcat`: the loop stops before `last`, then `last` is appended
  // once, so the interval never increments past `maxinteger`.
  let mut k = i
  while k < last {
    add_field(state, t, buf, k)
    buf.write_bytes(sep.view())
    k = k + 1L
  }
  if k == last {
    add_field(state, t, buf, last)
  }
  @core.One(@core.VStr(@core.LStr::of_bytes(buf.to_bytes())))
}

///|
fn add_field(
  state : @core.LuaState,
  t : @core.Value,
  buf : Buffer,
  k : Int64,
) -> Unit raise @core.LuaRaised {
  let v = geti(state, t, k)
  match v {
    @core.VStr(s) => buf.write_bytes(s.data().view())
    @core.VInt(_) | @core.VNum(_) =>
      buf.write_bytes(@core.number_to_bytes(v).view())
    _ =>
      @core.runtime_error(
        state,
        "invalid value (" +
        v.type_name() +
        ") at index " +
        k.to_string() +
        " in table for 'concat'",
      )
  }
}

///|
pub fn tbl_insert(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = checktab(
    state,
    args,
    1,
    "insert",
    index_of=true,
    newindex_of=true,
    length_of=true,
  )
  let n = objlen(state, t)
  // `luaL_intop(+, e, 1)` is unsigned arithmetic, so a length of `maxinteger`
  // really does wrap around to the first key here.
  let e = if n == max_i { min_i } else { n + 1L }
  let pos = if args.length() == 2 {
    e
  } else if args.length() == 3 {
    let p = @core.check_int(state, args, 2, "insert")
    // `p` has to lie in [1, e], compared as unsigned to keep the check free of
    // overflows.
    if !(p.reinterpret_as_uint64() - 1UL < e.reinterpret_as_uint64()) {
      @core.arg_error(state, 2, "insert", "position out of bounds")
    }
    let mut i = e
    while i > p {
      seti(state, t, i, geti(state, t, i - 1L))
      i = i - 1L
    }
    p
  } else {
    @core.runtime_error(state, "wrong number of arguments to 'insert'")
  }
  seti(state, t, pos, args[args.length() - 1])
  @core.Nothing
}

///|
pub fn tbl_remove(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = checktab(
    state,
    args,
    1,
    "remove",
    index_of=true,
    newindex_of=true,
    length_of=true,
  )
  let size = objlen(state, t)
  let mut pos = if args.length() >= 2 && !args[1].is_nil() {
    @core.check_int(state, args, 2, "remove")
  } else {
    size
  }
  // Only an explicit position needs validating: the default one is in range.
  if pos != size &&
    !(pos.reinterpret_as_uint64() - 1UL <= size.reinterpret_as_uint64()) {
    @core.arg_error(state, 2, "remove", "position out of bounds")
  }
  let v = geti(state, t, pos)
  while pos < size {
    seti(state, t, pos, geti(state, t, pos + 1L))
    pos = pos + 1L
  }
  seti(state, t, pos, @core.VNil)
  @core.One(v)
}

///|
pub fn tbl_move(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let f = @core.check_int(state, args, 2, "move")
  let e = @core.check_int(state, args, 3, "move")
  let t = @core.check_int(state, args, 4, "move")
  let has_dest = args.length() >= 5 && !args[4].is_nil()
  let a1 = checktab(
    state,
    args,
    1,
    "move",
    index_of=true,
    newindex_of=false,
    length_of=false,
  )
  let a2 = if has_dest {
    checktab(
      state,
      args,
      5,
      "move",
      index_of=false,
      newindex_of=true,
      length_of=false,
    )
  } else {
    a1
  }
  if e >= f {
    // Both bounds are checked so that neither the count nor a destination key
    // can wrap around.
    if !(f > 0L || e < max_i + f) {
      @core.arg_error(state, 3, "move", "too many elements to move")
    }
    let n = e - f + 1L
    if !(t <= max_i - n + 1L) {
      @core.arg_error(state, 4, "move", "destination wrap around")
    }
    // Forward is better for rehashing, and safe whenever the destination lies
    // past the source range, before it, or in another table.
    let dest_is_source = match (a1, a2) {
      (@core.VTable(x), @core.VTable(y)) => x.id == y.id
      _ => a1.raw_equal(a2)
    }
    let same = !has_dest || dest_is_source
    if t > e || t <= f || !same {
      let mut i = 0L
      while i < n {
        seti(state, a2, t + i, geti(state, a1, f + i))
        i = i + 1L
      }
    } else {
      let mut i = n - 1L
      while i >= 0L {
        seti(state, a2, t + i, geti(state, a1, f + i))
        i = i - 1L
      }
    }
  }
  @core.One(a2)
}

///|
pub fn tbl_pack(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let _ = state
  let t = @core.LTable::new()
  let mut i = 0
  while i < args.length() {
    t.set_int((i + 1).to_int64(), args[i])
    i = i + 1
  }
  t.set_str("n", @core.VInt(args.length().to_int64()))
  @core.One(@core.VTable(t))
}

///|
pub fn tbl_unpack(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  // Nothing is checked here: `tunpack` takes the range first and only then
  // asks for the length, so `table.unpack()` fails with the length error of a
  // nil value rather than an argument error.
  let t = if args.length() >= 1 { args[0] } else { @core.VNil }
  let i = @core.opt_int(state, args, 2, "unpack", 1L)
  let j = if args.length() >= 3 && !args[2].is_nil() {
    @core.check_int(state, args, 3, "unpack")
  } else {
    match to_integer(@vm.len(state, t)) {
      Some(n) => n
      None => 0L
    }
  }
  let out : Array[@core.Value] = []
  if i <= j {
    // Measured as an unsigned difference: a range that spans more than the
    // integer space would otherwise wrap around and loop forever.
    let minus_one = j.reinterpret_as_uint64() - i.reinterpret_as_uint64()
    // `lua_checkstack` refuses to grow past LUAI_MAXCSTACK, so an oversized
    // request is refused rather than exhausting the stack.
    if minus_one >= 8000UL {
      @core.runtime_error(state, "too many results to unpack")
    }
    let mut k = i
    // The last index is fetched outside the loop: `maxinteger` itself may be
    // requested, and one past it would wrap around and spin forever.
    while k < j {
      out.push(geti(state, t, k))
      k = k + 1L
    }
    out.push(geti(state, t, j))
  }
  @core.Many(out)
}

///|----------------------------------------------------------------
/// Installation

///|----------------------------------------------------------------

///|
pub fn open_table_library(state : @core.LuaState) -> Unit {
  let t = @core.LTable::new()
  t.set_str(
    "concat",
    @core.VBuiltin(@core.LBuiltin::make("concat", 4, tbl_concat)),
  )
  t.set_str(
    "insert",
    @core.VBuiltin(@core.LBuiltin::make("insert", 3, tbl_insert)),
  )
  t.set_str("move", @core.VBuiltin(@core.LBuiltin::make("move", 5, tbl_move)))
  t.set_str("pack", @core.VBuiltin(@core.LBuiltin::make("pack", -1, tbl_pack)))
  t.set_str(
    "remove",
    @core.VBuiltin(@core.LBuiltin::make("remove", 2, tbl_remove)),
  )
  t.set_str("sort", @core.VBuiltin(@core.LBuiltin::make("sort", 2, tbl_sort)))
  t.set_str(
    "unpack",
    @core.VBuiltin(@core.LBuiltin::make("unpack", 3, tbl_unpack)),
  )
  state.globals.set_str("table", @core.VTable(t))
}
