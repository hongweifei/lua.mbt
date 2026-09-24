// The interpreter state.

///|
pub const MAX_CALL_DEPTH : Int = 200

///|
pub(all) struct LuaState {
  globals : LTable
  registry : LTable
  main_thread : LThread
  mut current_thread : LThread
  mut native_depth : Int
  error_handler : Value
  mut memory_units : Int
  /// The live size past which allocation fails.  See `MEMORY_LIMIT`.
  mut memory_limit : Int
  in_error_handling : Bool
  mut gc_running : Bool
  /// True while a `__gc` handler runs.  The reference stops the collector from
  /// being entered again there (`GCSTPGC`), and every `collectgarbage` option
  /// then answers false rather than doing anything.
  mut gc_finalizing : Bool
  mut gc_mode : String
  mut gc_pause : Int
  mut gc_stepmul : Int
  mut warn_enabled : Bool
  mut last_error : Bytes
  /// The metamethod name of the call currently being dispatched, consumed
  /// by the next pushed frame so that `debug.getinfo` can report
  /// namewhat "metamethod".
  mut mm_name : String
  /// The stack slots holding the operands of the instruction now executing,
  /// so an error can name the faulty value.  -1 when the operand is a
  /// constant or is not a register at all.
  mut slot_x : Int
  mut slot_y : Int
  /// Extra frame slots granted while an error is being handled, so that a
  /// message handler still fits on a stack that has just overflowed.
  mut err_room : Int
  /// The collection cycle the collector is on.  Objects remember the last cycle
  /// that reached them (see `LTable.mark_epoch`), so no mark bits have to be
  /// cleared between cycles.
  mut gc_epoch : Int
  /// The tables that ask to be looked at every cycle: those whose metatable has
  /// a `__mode`.  Only these need registering, because reachability is computed
  /// from the roots rather than by sweeping a list of every object.
  weak_tables : Array[LTable]
  /// The objects whose metatable has a `__gc`, in creation order.
  mut finalizers : Array[Value]
  /// The allocation count at which the collector runs by itself.  It is a
  /// *safe point* rule: the interpreter checks it between two instructions,
  /// never inside one, so nothing the running instruction has half-built is
  /// looked at.
  mut gc_threshold : Int
  /// The reference's `GCdebt`, in bytes as its own is: a sized step adds
  /// kilobytes to it, a basic step clears it, and it is what `setpause` leaves
  /// *negative* -- a credit -- when a cycle ends.  While it is not positive
  /// `luaC_checkGC` does not step at all, which is what makes the calls after a
  /// collection do nothing until the credit is paid off.
  mut gc_debt : Int
  /// How much of the running cycle's work the steps have paid for.  A collection
  /// here is atomic, so the work of the phases is accounted rather than
  /// interleaved, and the cycle is finished when this covers what one owes.
  mut gc_units_done : Int
  /// How many objects the last cycle reached, and how many table slots they
  /// hold.  There is no live-size figure to be had otherwise, so the two stand
  /// for it: the next automatic collection is due a `gc_pause` per cent past
  /// them, as the reference's threshold is.
  mut gc_marked : Int
  /// The bytes the last cycle reached, which is what `collectgarbage("count")`
  /// reports and what the next threshold is measured from.  Host memory is
  /// reclaimed by reference counting, so a figure like the reference's
  /// `totalbytes` has to be computed: every object a cycle reaches adds its own
  /// size, and every string adds its bytes once.
  mut gc_marked_size : Int
  /// The ids of the strings already counted in the current measurement.  Equal
  /// strings share an id, so this is what keeps a string held in two places
  /// from counting twice.
  mut gc_counted_strings : Map[Int, Unit]
  /// The object bytes allocated when the last cycle ran, on the same footing as
  /// the string figure below: what a library function has made since is garbage
  /// the cycle has not reached yet, and `collectgarbage("count")` shows it.
  mut gc_object_base : Int
  /// The string bytes allocated when the last cycle ran.  What a program has
  /// created since then is garbage the cycle has not reached yet, and
  /// `collectgarbage("count")` shows it, as the reference's allocation counter
  /// does before a sweep.
  mut gc_string_base : Int
}

///|
/// How many allocation units pass between two automatic collections.  The
/// reference's pause parameter scales a similar distance from the live size;
/// this is a plain step, which is enough to make a loop that only allocates
/// reach a collection.
pub const GC_STEP : Int = 200 * 1024

///|
/// `GCPARAM_ADJ`: the reference keeps its collector parameters divided by this
/// and multiplies them back when it reports them, so a parameter a program sets
/// comes back rounded down to a multiple of it -- `setstepmul(50)` reports 48 the
/// next time it is asked for.  A parameter large enough to overflow the byte the
/// reference stores it in wraps there; here it is kept as it is, which is why an
/// extreme multiplier is clamped rather than wrapped.
pub const GCPARAM_ADJ : Int = 4

///|
/// `WORK2MEM`: the reference counts a step's debt in units of one slot
/// (`TValue`), so a byte figure reaches the same units by dividing by this.
pub const WORK2MEM : Int = 16

///|
/// `LUAI_GCSTEPSIZE`: the granularity one step is worth is 2^13 bytes, which in
/// the units above is 512.
pub const GC_STEP_SHIFT : Int = 13

///|
/// A bound on the debt a step can be given, so that an extreme step size a
/// program passes cannot wrap the arithmetic.  The reference has no such bound
/// because its `l_mem` is wider than the figures a program passes.
pub const GC_MAX_DEBT : Int64 = 1L << 40

///|
/// How much the live set may hold before the interpreter refuses to grow
/// further, in bytes.  The reference has no such figure: its allocator fails
/// (`luaM_realloc_` raising "not enough memory") when the host cannot give it
/// more, which on a 16 GB machine happens around 8.6 GB.  Memory here is owned
/// by the host runtime, which cannot refuse gracefully, so the interpreter keeps
/// its own budget and raises the reference's message.  `heavy.lua` fills a table
/// until that happens; it is also what keeps a runaway program from taking the
/// process down with it.
pub const MEMORY_LIMIT : Int = 1 << 30

///|
pub fn lua_state_new() -> LuaState {
  let globals = LTable::new()
  let registry = LTable::new()
  let main = LThread::new()
  let st : LuaState = {
    globals,
    registry,
    main_thread: main,
    current_thread: main,
    native_depth: 0,
    error_handler: VNil,
    memory_units: 0,
    memory_limit: MEMORY_LIMIT,
    in_error_handling: false,
    gc_running: true,
    gc_finalizing: false,
    gc_mode: "generational",
    gc_pause: 200,
    gc_stepmul: 100,
    warn_enabled: false,
    last_error: Bytes::new(0),
    mm_name: "",
    slot_x: -1,
    slot_y: -1,
    err_room: 0,
    gc_epoch: 1,
    weak_tables: [],
    finalizers: [],
    gc_threshold: GC_STEP,
    gc_debt: 0,
    gc_units_done: 0,
    gc_marked: 0,
    gc_marked_size: 0,
    gc_counted_strings: Map([]),
    gc_object_base: 0,
    gc_string_base: 0,
  }
  main.status = THREAD_RUNNING
  // The main thread is never yieldable: there is no coroutine to yield to.
  main.ny = 1
  st
}

///|----------------------------------------------------------------
/// Current position, used to prefix runtime errors so that a message produced
/// deep inside an operation still points at the Lua source that triggered it.

///|
/// `luaO_chunkid`: the source of a chunk as messages show it, shortened to fit
/// the fixed-size buffer the reference uses.
let id_size : Int = 60

///|
pub fn chunk_id_of(source : Bytes) -> String {
  let len = source.length()
  if len == 0 {
    return "[string \"\"]"
  }
  let body = bytes_slice(source, 1, len - 1)
  let c = ubyte_at(source, 0)
  // '=' names are used as they stand; a long one loses its tail.
  if c == 61 {
    if body.length() <= id_size - 1 {
      text_of(body)
    } else {
      text_of(bytes_slice(body, 0, id_size - 1))
    }
    // '@' names keep their tail behind an ellipsis.
  } else if c == 64 {
    if body.length() <= id_size - 1 {
      text_of(body)
    } else {
      let tail = id_size - 4
      "..." + text_of(bytes_slice(body, body.length() - tail, tail))
    }
    // Text given to 'load' appears as [string "..."].
  } else {
    // Room for the '[string "' prefix, the '"],' suffix, an ellipsis and the
    // terminator.
    let budget = id_size - 15
    let nl = find_byte(source, 10)
    let body_len = if nl >= 0 { nl } else { len }
    if nl < 0 && body_len < budget {
      "[string \"" + text_of(source) + "\"]"
    } else {
      let keep = if body_len > budget { budget } else { body_len }
      let dots = if body_len > budget || nl >= 0 { "..." } else { "" }
      "[string \"" + text_of(bytes_slice(source, 0, keep)) + dots + "\"]"
    }
  }
}

///|
fn find_byte(b : Bytes, c : Int) -> Int {
  let mut i = 0
  while i < b.length() {
    if ubyte_at(b, i) == c {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// The source of a chunk as it appears in error messages.  A function loaded
/// from a stripped binary chunk has no source and reports '?'.
pub fn source_for_message(source : Bytes) -> String {
  if is_no_source(source) || source.length() == 0 {
    "?"
  } else {
    chunk_id_of(source)
  }
}

///|
/// The source of a chunk that has none: the one that was dumped stripped.  An
/// empty source is *not* the same thing -- `load(s, "")` names a chunk with the
/// empty string, which the reference reports as `[string ""]`, while a stripped
/// one is reported as `?`.
pub fn no_source() -> LStr {
  LStr::of_bytes(b" ")
}

///|
/// Whether these bytes are that marker rather than a real name.
pub fn is_no_source(source : Bytes) -> Bool {
  source.length() == 1 && ubyte_at(source, 0) == 0
}

///|
/// Whether a prototype was given a source at all.
pub fn has_source(s : LStr) -> Bool {
  !is_no_source(s.data())
}

///|
pub fn current_position(st : LuaState) -> String {
  // This is the position `luaL_error` adds, which is `luaL_where(L, 1)`: the
  // frame *one level below* the running host function, and only when that frame
  // is a Lua function with a line.  A library function called from another
  // host function -- `pcall(string.rep)`, `pcall(error, "x")` -- therefore has
  // no position at all, where walking down to the nearest Lua frame would
  // wrongly borrow one.
  text_of(position_at_level(st, 1))
}

///|
/// The position a *runtime* error carries: the current frame's, and only when
/// that frame is a Lua function.  The reference's `luaG_runerror` adds source
/// information only for a Lua frame, so an error raised while a host function
/// is current -- `pcall(nil)` calling a value it cannot call -- has none, while
/// a library function adds its *caller's* position instead (`current_position`).
pub fn vm_position(st : LuaState) -> String {
  let th = st.current_thread
  let n = th.frames.length()
  if n == 0 {
    return ""
  }
  let fr = th.frames[n - 1]
  match fr.closure {
    Some(cl) =>
      source_for_message(cl.proto.source.data()) +
      ":" +
      line_at(cl.proto, fr.pc - 1).to_string() +
      ": "
    None => ""
  }
}

///|
/// Raises a runtime error, prefixed with the position `vm_position` gives.
pub fn[T] vm_error(st : LuaState, msg : String) -> T raise LuaRaised {
  raise_fresh(st, VStr(LStr::of_string(vm_position(st) + msg)))
}

///|----------------------------------------------------------------
/// Error reporting

///|
/// Raises a value as an error that has just been *created*, which is the only
/// kind the message handler of an enclosing `xpcall` is called for.  Everything
/// that invents an error goes through here; code that puts an error back in
/// flight while the stack unwinds does not, so it is reported once.
pub fn[T] raise_fresh(st : LuaState, v : Value) -> T raise LuaRaised {
  st.current_thread.fresh_error = true
  raise LuaRaised(v)
}

///|
/// Raises a runtime error, prefixed with the current position.
pub fn[T] runtime_error(st : LuaState, msg : String) -> T raise LuaRaised {
  raise_fresh(st, VStr(LStr::of_string(current_position(st) + msg)))
}

///|
/// Raises a runtime error whose message is already a byte string.
pub fn[T] runtime_error_bytes(st : LuaState, msg : Bytes) -> T raise LuaRaised {
  raise_fresh(
    st,
    VStr(LStr::of_bytes(bytes_concat([bytes_of(current_position(st)), msg]))),
  )
}

///|
/// Raises a value as an error, leaving it untouched.
pub fn[T] lua_state_raise_value(st : LuaState, v : Value) -> T raise LuaRaised {
  raise_fresh(st, v)
}

///|
/// `bad argument #n to 'fname' (msg)`
pub fn[T] arg_error(
  st : LuaState,
  n : Int,
  fname : String,
  msg : String,
) -> T raise LuaRaised {
  runtime_error(st, arg_message(st, n, fname, msg))
}

///|
/// The type name of a value as reported in argument errors.  Values with a
/// `__name` field report that name instead, which is how userdata types
/// announce themselves.
pub fn type_error_name(_st : LuaState, v : Value) -> String {
  match v {
    VTable(t) =>
      match t.meta {
        Some(mt) =>
          match mt.get_str("__name") {
            VStr(s) => text_of(s.data())
            _ => "table"
          }
        None => "table"
      }
    VUserData(u) =>
      match u.meta {
        Some(mt) =>
          match mt.get_str("__name") {
            VStr(s) => text_of(s.data())
            _ => userdata_name(u)
          }
        None => userdata_name(u)
      }
    _ => v.type_name()
  }
}

///|
/// What an argument error calls a userdata: `luaL_typeerror` says "light
/// userdata" for one of the light kind, while `type` calls both "userdata".
fn userdata_name(u : LUserData) -> String {
  if u.light {
    "light userdata"
  } else {
    "userdata"
  }
}

///|----------------------------------------------------------------
/// Argument checking

///|
pub fn check_any(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
) -> Value raise LuaRaised {
  if n > args.length() {
    arg_error(st, n, fname, "value expected")
  }
  args[n - 1]
}

///|
/// The value at `n`, or an argument error naming the type that was expected.
/// A typed check cannot share `check_any`'s message: the reference reports a
/// missing argument as "no value" through `luaL_typeerror`, so `string.rep()`
/// says "string expected, got no value" while `pcall()` says "value expected".
pub fn check_present(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
  expected : String,
) -> Value raise LuaRaised {
  if n > args.length() {
    arg_error(st, n, fname, expected + " expected, got no value")
  }
  args[n - 1]
}

///|
pub fn check_int(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
) -> Int64 raise LuaRaised {
  let v = check_present(st, args, n, fname, "number")
  match v {
    VInt(i) => i
    VNum(d) =>
      if float_is_int64(d) {
        float_to_int64(d)
      } else {
        arg_error(st, n, fname, "number has no integer representation")
      }
    VStr(s) =>
      match lua_str2num(s.data()) {
        Some(NInt(i)) => i
        Some(NFloat(d)) =>
          if float_is_int64(d) {
            float_to_int64(d)
          } else {
            arg_error(st, n, fname, "number has no integer representation")
          }
        None => arg_error(st, n, fname, "number expected, got string")
      }
    _ =>
      arg_error(st, n, fname, "number expected, got " + type_error_name(st, v))
  }
}

///|
pub fn check_number(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
) -> Double raise LuaRaised {
  let v = check_present(st, args, n, fname, "number")
  match value_to_double_or_string(v) {
    Some(d) => d
    None =>
      arg_error(st, n, fname, "number expected, got " + type_error_name(st, v))
  }
}

///|
/// Numeric coercion for `check_number`, which accepts numeric strings.
pub fn value_to_double_or_string(v : Value) -> Double? {
  match v {
    VInt(i) => Some(i.to_double())
    VNum(d) => Some(d)
    VStr(s) =>
      match lua_str2num(s.data()) {
        Some(NInt(i)) => Some(i.to_double())
        Some(NFloat(d)) => Some(d)
        None => None
      }
    _ => None
  }
}

///|
pub fn check_str(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
) -> LStr raise LuaRaised {
  let v = check_present(st, args, n, fname, "string")
  match v {
    VStr(s) => s
    VInt(i) => LStr::of_bytes(int64_to_bytes(i))
    VNum(d) => LStr::of_bytes(double_to_g14(d))
    _ =>
      arg_error(st, n, fname, "string expected, got " + type_error_name(st, v))
  }
}

///|
pub fn check_table(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
) -> LTable raise LuaRaised {
  let v = check_present(st, args, n, fname, "table")
  match v {
    VTable(t) => t
    _ =>
      arg_error(st, n, fname, "table expected, got " + type_error_name(st, v))
  }
}

///|
pub fn check_function(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
) -> Value raise LuaRaised {
  let v = check_present(st, args, n, fname, "function")
  match v {
    VFunc(_) | VBuiltin(_) => v
    _ =>
      arg_error(
        st,
        n,
        fname,
        "function expected, got " + type_error_name(st, v),
      )
  }
}

///|
/// The thread at `n`, or an argument error naming the expected type -- the
/// reference's `getco`, which is what every `coroutine` function that takes one
/// uses.
pub fn check_thread(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
) -> LThread raise LuaRaised {
  let v = check_present(st, args, n, fname, "thread")
  match v {
    VThread(t) => t
    _ =>
      arg_error(st, n, fname, "thread expected, got " + type_error_name(st, v))
  }
}

///|
pub fn check_option(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
  options : Array[String],
  dflt : String,
) -> String raise LuaRaised {
  if args.length() < n || args[n - 1].is_nil() {
    return dflt
  }
  let s = check_str(st, args, n, fname)
  let t = text_of(s.data())
  for o in options {
    if o == t {
      return t
    }
  }
  arg_error(st, n, fname, "invalid option '" + t + "'")
}

///|
/// Optional integer argument.
pub fn opt_int(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
  dflt : Int64,
) -> Int64 raise LuaRaised {
  if args.length() < n || args[n - 1].is_nil() {
    return dflt
  }
  check_int(st, args, n, fname)
}

///|
/// Optional number argument.
pub fn opt_number(
  st : LuaState,
  args : Array[Value],
  n : Int,
  fname : String,
  dflt : Double,
) -> Double raise LuaRaised {
  if args.length() < n || args[n - 1].is_nil() {
    return dflt
  }
  check_number(st, args, n, fname)
}

///|
pub fn is_truthy_arg(st : LuaState, args : Array[Value], n : Int) -> Bool {
  let _ = st
  if args.length() < n {
    return false
  }
  args[n - 1].is_truthy()
}

///|
/// The `chunk:line: ` prefix of the frame `level` steps up the stack.  Level 1
/// is the function that called the running native function, which is what
/// `error(msg, level)` reports.
pub fn position_at_level(st : LuaState, level : Int) -> Bytes {
  let thread = st.current_thread
  // The frames above the running native are the ones being described.
  let top = thread.frames.length() - 2
  let idx = top - (level - 1)
  if idx < 0 || idx >= thread.frames.length() {
    return Bytes::new(0)
  }
  let fr = thread.frames[idx]
  match fr.closure {
    Some(cl) =>
      bytes_of(
        source_for_message(cl.proto.source.data()) +
        ":" +
        line_at(cl.proto, fr.pc - 1).to_string() +
        ": ",
      )
    None => Bytes::new(0)
  }
}

///|
/// A string error value with a position in front of it.  This is what `error`,
/// `assert` and `coroutine.wrap` all do -- the reference's `luaB_error` -- so a
/// value that is not a string is handed back unchanged, and `level` decides
/// which frame the position comes from (`position_at_level`).
pub fn with_position(st : LuaState, v : Value, level : Int) -> Value {
  match v {
    VStr(s) =>
      if level > 0 {
        VStr(
          LStr::of_bytes(bytes_concat([position_at_level(st, level), s.data()])),
        )
      } else {
        v
      }
    _ => v
  }
}
