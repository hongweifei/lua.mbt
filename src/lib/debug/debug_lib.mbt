// Library registration and shared helpers for the debug library.

///|
/// The name of the registry key holding the weak table that the reference
/// implementation uses to store hook-related function names.
pub const HOOKKEY : String = "_HOOKKEY"

///|
/// Installs the debug library into the global table.
pub fn open_debug_library(st : @core.LuaState) -> Unit {
  let lib = @core.LTable::new()
  lib.set_str(
    "traceback",
    @core.VBuiltin(@core.LBuiltin::make("traceback", 0, db_traceback)),
  )
  lib.set_str(
    "getinfo",
    @core.VBuiltin(@core.LBuiltin::make("getinfo", 0, db_getinfo)),
  )
  lib.set_str(
    "getlocal",
    @core.VBuiltin(@core.LBuiltin::make("getlocal", 0, db_getlocal)),
  )
  lib.set_str(
    "setlocal",
    @core.VBuiltin(@core.LBuiltin::make("setlocal", 0, db_setlocal)),
  )
  lib.set_str(
    "getupvalue",
    @core.VBuiltin(@core.LBuiltin::make("getupvalue", 0, db_getupvalue)),
  )
  lib.set_str(
    "setupvalue",
    @core.VBuiltin(@core.LBuiltin::make("setupvalue", 0, db_setupvalue)),
  )
  lib.set_str(
    "upvalueid",
    @core.VBuiltin(@core.LBuiltin::make("upvalueid", 0, db_upvalueid)),
  )
  lib.set_str(
    "upvaluejoin",
    @core.VBuiltin(@core.LBuiltin::make("upvaluejoin", 0, db_upvaluejoin)),
  )
  lib.set_str(
    "getregistry",
    @core.VBuiltin(@core.LBuiltin::make("getregistry", 0, db_getregistry)),
  )
  lib.set_str(
    "getmetatable",
    @core.VBuiltin(@core.LBuiltin::make("getmetatable", 0, db_getmetatable)),
  )
  lib.set_str(
    "setmetatable",
    @core.VBuiltin(@core.LBuiltin::make("setmetatable", 0, db_setmetatable)),
  )
  lib.set_str(
    "getuservalue",
    @core.VBuiltin(@core.LBuiltin::make("getuservalue", 0, db_getuservalue)),
  )
  lib.set_str(
    "setuservalue",
    @core.VBuiltin(@core.LBuiltin::make("setuservalue", 0, db_setuservalue)),
  )
  lib.set_str(
    "sethook",
    @core.VBuiltin(@core.LBuiltin::make("sethook", 0, db_sethook)),
  )
  lib.set_str(
    "gethook",
    @core.VBuiltin(@core.LBuiltin::make("gethook", 0, db_gethook)),
  )
  lib.set_str(
    "debug",
    @core.VBuiltin(@core.LBuiltin::make("debug", 0, db_debug)),
  )
  lib.set_str(
    "setcstacklimit",
    @core.VBuiltin(@core.LBuiltin::make("setcstacklimit", 0, db_setcstacklimit)),
  )
  st.globals.set_str("debug", @core.VTable(lib))
  // The weak table the reference implementation keeps under registry._HOOKKEY.
  let hookkey = @core.LTable::new()
  let mt = @core.LTable::new()
  mt.set_str("__mode", @core.VStr(@core.LStr::of_string("k")))
  hookkey.meta = Some(mt)
  st.registry.set_str(HOOKKEY, @core.VTable(hookkey))
}

///|
/// The thread a debug function operates on: an explicit thread argument
/// shifts all other arguments by one.  Returns the thread and the index of
/// the first remaining argument (1-based).
pub fn get_thread(
  st : @core.LuaState,
  args : Array[@core.Value],
) -> (@core.LThread, Int) {
  if args.length() > 0 {
    match args[0] {
      @core.VThread(t) => return (t, 2)
      _ => ()
    }
  }
  (st.current_thread, 1)
}

///|
/// The n-th (1-based) argument, or nil when absent.
pub fn arg_or_nil(args : Array[@core.Value], n : Int) -> @core.Value {
  if n >= 1 && n <= args.length() {
    args[n - 1]
  } else {
    @core.VNil
  }
}

///|
/// Resolves the function-or-level argument of getinfo/traceback-style APIs.
pub fn is_function_arg(v : @core.Value) -> Bool {
  match v {
    @core.VFunc(_) | @core.VBuiltin(_) => true
    _ => false
  }
}
