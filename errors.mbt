///|
/// Why a call did not succeed: a chunk that failed to compile, a Lua error that
/// escaped, or a result that is not the kind the host asked for.  The error
/// *object* is kept as Lua made it, so a program that raises a table can be
/// inspected field by field.
pub struct LuaError {
  /// The error object itself.  For a chunk that never compiled, the message
  /// text, which is what `load` answers with.
  value : Value
  /// The text Lua would print for it: `tostring` when the object has one, and
  /// the reference's "(error object is a table value)" when it does not.
  message : String
}

///|
pub impl Show for LuaError with fn output(self, fmt) {
  fmt.write_string(self.message)
}

///|
/// The message of an error value, reported the way the language reports it: its
/// own `__tostring` when it has one, the reference's wording when it does not.
fn LuaError::of(st : @core.LuaState, value : Value) -> LuaError {
  { value, message: @core.text_of(@lualib.error_message(st, value)), }
}

///|
/// The failure of a chunk that did not compile, whose message the state carries.
fn LuaError::of_load(st : @core.LuaState) -> LuaError {
  let msg = match @lualib.last_load_error(st) {
    Some(b) => @core.text_of(b)
    None => "unknown error"
  }
  { value: Value::text(msg), message: msg, }
}

///|
/// A host asking for one kind of value and getting another.
fn LuaError::expected(
  st : @core.LuaState,
  wanted : String,
  got : Value,
) -> LuaError {
  LuaError::of(st, Value::text(wanted + " expected, got " + got.type_name()))
}
