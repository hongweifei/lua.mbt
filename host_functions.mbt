///|----------------------------------------------------------------
/// Host functions
///
/// A MoonBit closure becomes a Lua function, so a script can call back into the
/// program that embedded it.  The shape is the language's own: a function takes
/// whatever arguments it was given and answers with as many values as it likes,
/// and `select('#', ...)` counts them the way it does for a library function.
/// An `Err` raises that value as a Lua error, which a script can catch with
/// `pcall`.

///|----------------------------------------------------------------

///|
/// A function the host writes and Lua calls: the arguments in order, the values
/// to answer with, or the error object to raise.
pub type HostFunction = (Array[Value]) -> Result[Array[Value], Value]

///|
/// A value holding a host function, which can go anywhere a Lua function can:
/// a global, a table field, an argument to a call.
///
/// ```mbt check
/// test "a host closure called from Lua" {
///   let lua = Lua::new()
///   lua.set_function("长度", fn(args) {
///     match args[0].as_bytes() {
///       Some(b) => Ok([Value::VInt(b.length().to_int64())])
///       None => Err(Value::text("string expected"))
///     }
///   })
///   let vs = lua.run("return 长度('你好'), 长度('abc')").unwrap()
///   assert_eq(vs[0].as_integer(), Some(6L))
///   assert_eq(vs[1].as_integer(), Some(3L))
///   // An `Err` raises, so the script sees an ordinary Lua error it can catch.
///   let caught = lua.run("return select(2, pcall(长度, 1))").unwrap()
///   assert_true(caught[0].as_text().unwrap_or("").contains("string expected"))
/// }
/// ```
pub fn host_function(name : String, f : HostFunction) -> Value {
  fn body(
    state : @core.LuaState,
    upvals : Array[@core.Value],
    args : ArrayView[@core.Value],
  ) -> @core.BuiltinResult raise @core.LuaRaised {
    let _ = state
    let _ = upvals
    match f(args.to_owned()) {
      Ok([]) => @core.Nothing
      Ok([v]) => @core.One(v)
      Ok([a, b]) => @core.Two(a, b)
      Ok(rest) => @core.Many(rest)
      Err(e) => raise @core.LuaRaised(e)
    }
  }
  @core.VBuiltin(@core.LBuiltin::make(name, -1, body))
}

///|
/// Installs a host function as a global, which is how a script finds it:
/// `lua.set_function("load_config", ...)` makes `load_config()` callable.
pub fn Lua::set_function(self : Lua, name : String, f : HostFunction) -> Unit {
  @lualib.set_global(self.st, name, host_function(name, f))
}

///|
/// A host function cannot yield: `coroutine.resume` drives Lua frames, and a
/// closure that returns has no point to come back to.  A script that needs a
/// resumable host call uses a Lua function that calls the host function and
/// yields around it.
