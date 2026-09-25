// Runtime objects: prototypes, closures, upvalues, native functions, threads,

///|
/// The channel every jump out of a nested call travels on.  It carries errors
/// and, as its second case, a `coroutine.yield` that happened while the host had
/// called back into Lua: the MoonBit frames in between are the only way out of
/// such a call, so a yield rides the same channel.  It is not an error -- nothing
/// unwinds, the frames stay where they are -- and `execute` turns it back into a
/// yield of the frame it came from.  Every handler that would swallow an error
/// must let this one through.
pub(all) suberror LuaRaised {
  LuaRaised(Value)
  LuaYield(Array[Value])
}

///|
/// How a descriptor describes the origin of an upvalue.
pub(all) struct UpvalDesc {
  name : LStr
  in_stack : Bool
  index : Int
  /// The attribute of the variable this upvalue captured, so that assigning to
  /// a `const` from an inner function is still rejected.
  attrib : Int
}

///|
/// A local variable, kept for diagnostics and for the `debug` library.
pub(all) struct LocVar {
  name : LStr
  start_pc : Int
  mut end_pc : Int
  /// `ATTRIB_NONE`, `ATTRIB_CONST` or `ATTRIB_CLOSE`.
  attrib : Int
}

///|
/// A compiled function.
pub(all) struct LProto {
  code : Array[Instr]
  lines : Array[Int]
  constants : Array[Value]
  protos : Array[LProto]
  upvals : Array[UpvalDesc]
  numparams : Int
  is_vararg : Bool
  maxstack : Int
  source : LStr
  line_defined : Int
  last_line_defined : Int
  locvars : Array[LocVar]
  /// A readable name such as `function 'f'`, empty for anonymous functions.
  name : String
}

///|
pub fn line_at(p : LProto, pc : Int) -> Int {
  if pc >= 0 && pc < p.lines.length() {
    p.lines[pc]
  } else {
    -1
  }
}

///|
/// Where a closure may be entered from, used to build readable names.
pub fn describe(p : LProto) -> String {
  if p.line_defined == 0 {
    "main chunk"
  } else {
    "function <" +
    text_of(p.source.data()) +
    ":" +
    p.line_defined.to_string() +
    ">"
  }
}

///|
/// An upvalue cell.  While the enclosing function is running and the variable
/// still lives on the stack, the cell points into the thread stack; once the
/// scope ends the value is copied out and the cell becomes independent.
pub(all) struct LUpval {
  mut open : Bool
  mut value : Value
  index : Int
  mut owner : LThread?
  id : Int
  /// The stable userdata `debug.upvalueid` returns for this cell, created
  /// lazily so that the same cell always yields the same identity.
  mut id_tag : Value
}

///|
pub fn LUpval::new_closed(v : Value) -> LUpval {
  {
    open: false,
    value: v,
    index: 0,
    owner: None,
    id_tag: VNil,
    id: next_object_id(),
  }
}

///|
pub fn LUpval::get(self : LUpval) -> Value {
  if self.open {
    match self.owner {
      Some(th) => th.stack[self.index]
      None => self.value
    }
  } else {
    self.value
  }
}

///|
pub fn LUpval::set(self : LUpval, v : Value) -> Unit {
  if self.open {
    match self.owner {
      Some(th) => th.stack[self.index] = v
      None => self.value = v
    }
  } else {
    self.value = v
  }
}

///|
/// Releases the cell from the stack, copying the current value out.
pub fn LUpval::close(self : LUpval) -> Unit {
  if self.open {
    match self.owner {
      Some(th) => self.value = th.stack[self.index]
      None => ()
    }
    self.open = false
    self.owner = None
  }
}

///|
/// A Lua closure: a prototype together with the upvalue cells it captured.
pub(all) struct LClosure {
  proto : LProto
  upvals : Array[LUpval]
  id : Int
  /// The collection cycle that last reached this closure (see `LTable`).
  mut mark_epoch : Int
}

///|
/// Behaviour that the virtual machine must give special treatment.
pub const BK_NORMAL : Int = 0

///|
/// `coroutine.yield`: suspend the running thread.
pub const BK_YIELD : Int = 1

///|
/// `pcall`: call the target under protection so that the error can be caught
/// without unwinding the native stack.
pub const BK_PCALL : Int = 2

///|
pub const BK_XPCALL : Int = 3

///|
/// `pairs`, which is yieldable when the table has a `__pairs`: its whole
/// remaining work is to return the three values the metamethod produced, so a
/// yield inside it is finished by handing those values to the call instead of
/// running the builtin again.
pub const BK_PAIRS : Int = 4

///|
/// What a builtin answers with.
///
/// A builtin used to build a list on every call -- one heap allocation, and the
/// reference counting that comes with it, in the path of every standard library
/// call -- even though nearly all of them answer with one value or none.  These
/// say what the answer is without building anything; `Many` is for the answers
/// that are genuinely a list, either because their number is not known until
/// the call runs or because there are more than two of them.
#valtype
pub(all) enum BuiltinResult {
  /// No values.
  Nothing
  /// One value.
  One(Value)
  /// Two values, which is what `next`, `ipairs`' iterator and `math.modf` give.
  Two(Value, Value)
  /// A list the call built.
  Many(Array[Value])
}

///|
/// A native (host) function.  `upvals` are the values a native closure captured
/// when it was created, which is how functions like `string.gmatch` iterators
/// keep their state.
pub(all) struct LBuiltin {
  name : String
  kind : Int
  arity : Int
  body : (LuaState, Array[Value], ArrayView[Value]) -> BuiltinResult raise LuaRaised
  upvals : Array[Value]
  id : Int
  /// The collection cycle that last reached this builtin (see `LTable`).
  mut mark_epoch : Int
}

///|
pub fn LBuiltin::make(
  name : String,
  arity : Int,
  body : (LuaState, Array[Value], ArrayView[Value]) -> BuiltinResult raise LuaRaised,
) -> LBuiltin {
  make_builtin(name, BK_NORMAL, arity, body, [])
}

///|
pub fn LBuiltin::make_kind(
  name : String,
  kind : Int,
  arity : Int,
  body : (LuaState, Array[Value], ArrayView[Value]) -> BuiltinResult raise LuaRaised,
) -> LBuiltin {
  make_builtin(name, kind, arity, body, [])
}

///|
pub fn make_builtin(
  name : String,
  kind : Int,
  arity : Int,
  body : (LuaState, Array[Value], ArrayView[Value]) -> BuiltinResult raise LuaRaised,
  upvals : Array[Value],
) -> LBuiltin {
  { name, kind, arity, body, upvals, id: next_object_id(), mark_epoch: 0, }
}

///|
pub fn Value::as_builtin(self : Value) -> LBuiltin? {
  match self {
    VBuiltin(b) => Some(b)
    _ => None
  }
}

///|----------------------------------------------------------------
/// Threads

///|
/// The bytes every table, closure, thread and userdata created so far occupies,
/// on the same clock as the string one and for the same reason: what a program
/// has allocated since the last cycle is what `collectgarbage("count")` reports
/// on top of what the cycle measured.  It only ever grows.
let obj_allocated_bytes : Ref[Int] = Ref(0)

///|
/// Charges one object to the clock, where the object is made.  A creator that
/// can reach the state charges its own accounting instead (the interpreter's
/// `OP_NEWTABLE` and `OP_CLOSURE`, and what a table grows by); this is for the
/// objects a library function makes, which has no state in hand.
pub fn charge_object_bytes(n : Int) -> Unit {
  obj_allocated_bytes.val = obj_allocated_bytes.val + n
}

///|
pub fn LThread::new() -> LThread {
  charge_object_bytes(200)
  {
    stack: [],
    frames: [],
    open_upvals: [],
    meta: None,
    status: THREAD_SUSPENDED,
    ny: 0,
    ccalls: 0,
    func: VNil,
    started: false,
    dead_error: VNil,
    resume_vals: None,
    hook_fn: VNil,
    hook_mask: 0,
    hook_count: 0,
    hook_base_count: 0,
    hook_running: false,
    hook_old_pc: 0,
    mm_pending: "",
    errfunc: VNil,
    in_errfunc: false,
    fresh_error: false,
    id: next_object_id(),
    mark_epoch: 0,
  }
}

///|
pub fn LThread::ensure_stack(self : LThread, n : Int) -> Unit {
  while self.stack.length() < n {
    self.stack.push(VNil)
  }
}

///|
pub fn LThread::current_frame(self : LThread) -> Frame? {
  let n = self.frames.length()
  if n == 0 {
    None
  } else {
    Some(self.frames[n - 1])
  }
}

///|----------------------------------------------------------------
/// Userdata

///|----------------------------------------------------------------
