// Metatables, and the indexing operations that consult them.

///|
/// The metatable of a value.  Tables and userdata carry their own; every other
/// type shares one per type, which is how `debug.setmetatable` works.
pub fn metatable_of(st : @core.LuaState, v : @core.Value) -> @core.LTable? {
  match v {
    @core.VTable(t) => t.meta
    @core.VUserData(u) => u.meta
    _ =>
      match st.registry.get_str("__mt_" + v.type_name()) {
        @core.VTable(t) => Some(t)
        _ => None
      }
  }
}

///|
/// Sets the metatable of a value.  Only tables and userdata have a per value
/// metatable; other types share one.
pub fn set_metatable_of(
  st : @core.LuaState,
  v : @core.Value,
  mt : @core.LTable?,
) -> Unit {
  match v {
    @core.VTable(t) => t.set_metatable(mt)
    @core.VUserData(u) => u.meta = mt
    _ =>
      match mt {
        Some(t) => st.registry.set_str("__mt_" + v.type_name(), @core.VTable(t))
        None => {
          let _ = st.registry.set(
            @core.VStr(@core.LStr::of_string("__mt_" + v.type_name())),
            @core.VNil,
          )
        }
      }
  }
  // A `__mode` or `__gc` in the metatable is what makes the collector look at
  // this value every cycle.
  @core.gc_register(st, v)
}

///|
/// Reads a metamethod, or nil when there is no metatable or no such field.
pub fn metafield(
  st : @core.LuaState,
  v : @core.Value,
  name : String,
) -> @core.Value {
  match metatable_of(st, v) {
    Some(mt) => mt.hash_get(@core.KStr(@core.LStr::of_string(name)))
    None => @core.VNil
  }
}

///|
/// The name `debug.getinfo` reports for a frame entered through a metamethod:
/// the event with its `__` prefix removed.
pub fn metamethod_report(name : String) -> String {
  if name.length() > 2 {
    name[2:].to_owned()
  } else {
    ""
  }
}

///|
/// Calls a metamethod.  `report` is the name `debug.getinfo` gives the frame the
/// metamethod runs in: the reference derives it from the instruction that
/// triggered the call, so a metamethod entered from the host reports no name at
/// all.
///
/// A metamethod is *not* a non-yieldable boundary: the reference calls it with
/// `luaD_call`, so a `__close` handler that yields suspends the coroutine and
/// finishes when it is resumed.  What a yield needs is a frame that can run its
/// instruction again, and `call_value` is where that is decided.
pub fn call_metamethod(
  st : @core.LuaState,
  f : @core.Value,
  args : Array[@core.Value],
  want : Int,
  report : String,
) -> Array[@core.Value] raise @core.LuaRaised {
  let saved_mm = st.mm_name
  st.mm_name = report
  let r = Ok(call_value(st, f, args, want)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(v) => raise @core.LuaYield(v)
  }
  st.mm_name = saved_mm
  match r {
    Ok(v) => v
    Err(e) => raise @core.LuaRaised(e)
  }
}

///|
pub fn is_callable(v : @core.Value) -> Bool {
  match v {
    @core.VFunc(_) | @core.VBuiltin(_) => true
    _ => false
  }
}

///|----------------------------------------------------------------
/// Indexing

///|----------------------------------------------------------------

///|
/// Reads `t[k]`, following `__index` chains.  `src` describes the syntactic
/// origin of the indexed value, so that the error reads like the reference
/// implementation's.
pub fn gettable(
  st : @core.LuaState,
  t : @core.Value,
  k : @core.Value,
  src : Int,
) -> @core.Value raise @core.LuaRaised {
  let mut cur = t
  // Where the value being indexed was read from, for the error that reports it.
  // Only the first pass reads a register: everything after it came out of a
  // metatable, which the reference's `instack` does not find in the stack
  // either, so it has no name to report.
  let mut name_src = src
  let mut steps = 0
  while steps < 100 {
    steps = steps + 1
    match cur {
      @core.VTable(tbl) => {
        let v = tbl.get(k)
        if !v.is_nil() {
          return v
        }
        let handler = metafield(st, cur, "__index")
        if handler.is_nil() {
          return @core.VNil
        }
        if is_callable(handler) {
          let res = call_metamethod(st, handler, [cur, k], 1, "index")
          return nth_or_nil(res, 0)
        }
        cur = handler
      }
      @core.VUserData(_) => {
        let handler = metafield(st, cur, "__index")
        if is_callable(handler) {
          let res = call_metamethod(st, handler, [cur, k], 1, "index")
          return nth_or_nil(res, 0)
        }
        if handler.is_nil() {
          type_error(st, "index", cur, @core.operand_info(st, name_src))
        }
        cur = handler
      }
      _ => {
        let handler = metafield(st, cur, "__index")
        if is_callable(handler) {
          let res = call_metamethod(st, handler, [cur, k], 1, "index")
          return nth_or_nil(res, 0)
        }
        if handler.is_nil() {
          type_error(st, "index", cur, @core.operand_info(st, name_src))
        }
        cur = handler
      }
    }
    name_src = @core.src_none
  }
  @core.vm_error(st, "'__index' chain too long; possible loop")
}

///|
/// Charges what a table grew by and refuses once the interpreter's estimate is
/// past its budget.  The reference fails inside the allocator (`luaM_realloc_`
/// raising "not enough memory"); memory here belongs to the host runtime, which
/// cannot refuse gracefully, so the limit is the interpreter's own and the
/// message is the reference's.
fn charge_growth(
  st : @core.LuaState,
  t : @core.LTable,
  before : Int,
) -> Unit raise @core.LuaRaised {
  let after = @core.table_bytes(t)
  if after > before {
    st.memory_units = st.memory_units + (after - before)
  }
  if st.memory_units >= st.memory_limit {
    @core.raise_fresh(
      st,
      @core.VStr(@core.LStr::of_string("not enough memory")),
    )
  }
}

///|
/// `t[k]`, with the answer the table itself gives taken directly.  Two things
/// are saved on the common path: an integer or a string key is read as it is,
/// without being normalised into a `Key` first, and a key the table holds ends
/// the matter right there -- a metatable only ever answers for a key it does
/// not (the reference's `luaV_fastget`).
pub fn index_get(
  st : @core.LuaState,
  t : @core.Value,
  k : @core.Value,
  src : Int,
) -> @core.Value raise @core.LuaRaised {
  match t {
    @core.VTable(tbl) => {
      let v = match k {
        @core.VInt(i) => tbl.get_int(i)
        @core.VStr(s) => tbl.get_lstr(s)
        _ => @core.VNil
      }
      if v.is_nil() {
        gettable(st, t, k, src)
      } else {
        v
      }
    }
    _ => gettable(st, t, k, src)
  }
}

///|
/// `t[k] = v` for a table with no metatable, which is most stores: no
/// `__newindex` can apply to it, so nothing has to be looked up before the store
/// and nothing charged for it unless the table actually grew.  False means the
/// general path has to run instead -- there is a metatable, which the reference
/// consults for a key the table does not hold, or the key is one no table can
/// hold.
pub fn index_set(
  st : @core.LuaState,
  t : @core.Value,
  k : @core.Value,
  v : @core.Value,
  src : Int,
) -> Unit raise @core.LuaRaised {
  match t {
    @core.VTable(tbl) =>
      if tbl.meta is None {
        let before = @core.table_bytes(tbl)
        match k {
          @core.VInt(i) => tbl.set_int(i, v)
          @core.VStr(s) => tbl.set_lstr(s, v)
          _ => if !tbl.set(k, v) { invalid_key_error(st, k) }
        }
        if @core.table_bytes(tbl) > before {
          charge_growth(st, tbl, before)
        }
      } else {
        settable(st, t, k, v, src)
      }
    _ => settable(st, t, k, v, src)
  }
}

///|
/// Writes `t[k] = v`, following `__newindex` chains.
pub fn settable(
  st : @core.LuaState,
  t : @core.Value,
  k : @core.Value,
  v : @core.Value,
  src : Int,
) -> Unit raise @core.LuaRaised {
  let mut cur = t
  // As in `gettable`, only the first pass reads a register.
  let mut name_src = src
  let mut steps = 0
  while steps < 100 {
    steps = steps + 1
    match cur {
      @core.VTable(tbl) => {
        let before = @core.table_bytes(tbl)
        if !tbl.get(k).is_nil() {
          if !tbl.set(k, v) {
            invalid_key_error(st, k)
          }
          charge_growth(st, tbl, before)
          return
        }
        let handler = metafield(st, cur, "__newindex")
        if handler.is_nil() {
          if !tbl.set(k, v) {
            invalid_key_error(st, k)
          }
          charge_growth(st, tbl, before)
          return
        }
        if is_callable(handler) {
          let _ = call_metamethod(st, handler, [cur, k, v], 0, "newindex")
          return
        }
        cur = handler
      }
      @core.VUserData(_) => {
        let handler = metafield(st, cur, "__newindex")
        if is_callable(handler) {
          let _ = call_metamethod(st, handler, [cur, k, v], 0, "newindex")
          return
        }
        if handler.is_nil() {
          type_error(st, "index", cur, @core.operand_info(st, name_src))
        }
        cur = handler
      }
      _ => {
        let handler = metafield(st, cur, "__newindex")
        if is_callable(handler) {
          let _ = call_metamethod(st, handler, [cur, k, v], 0, "newindex")
          return
        }
        type_error(st, "index", cur, @core.operand_info(st, name_src))
      }
    }
    name_src = @core.src_none
  }
  @core.vm_error(st, "'__newindex' chain too long; possible loop")
}
