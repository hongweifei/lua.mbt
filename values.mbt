///|----------------------------------------------------------------
/// Values at the host boundary
///
/// The interpreter's own value is re-exported rather than copied, so a table or
/// a function a host holds *is* the object Lua sees: changing one changes the
/// other, and comparing two hosts' handles compares identity the way `==` does.
/// `Bytes` stays the exact reading of a string, because a Lua string is bytes;
/// the `String` forms are the convenience, and they say so.

///|----------------------------------------------------------------

///|
/// A Lua value.  Its cases are the interpreter's own (`Value::VInt`, `Value::VStr`,
/// ...), and reading one with a coercion rule is what the methods below are for.
pub type Value = @core.Value

///|
/// A Lua table, with the interpreter's own accessors (`get_str`, `set_str`,
/// `get_int`, `set_int`, `length`, ...).
pub type Table = @core.LTable

///|
/// A value a host can hand to Lua.  Implemented for the MoonBit scalars, for
/// `Bytes`, for `Table` and `Value` themselves, for `Option` (`None` becomes
/// `nil`), for `Array` (a sequence numbered from 1) and for `Map`.
pub trait ToLua {
  fn to_lua(Self) -> Value
}

///|
#warnings("-unused_value")
pub impl ToLua for Value with fn to_lua(self) -> Value {
  self
}

///|
#warnings("-unused_value")
pub impl ToLua for Bool with fn to_lua(self) -> Value {
  @core.VBool(self)
}

///|
#warnings("-unused_value")
pub impl ToLua for Int with fn to_lua(self) -> Value {
  @core.VInt(self.to_int64())
}

///|
#warnings("-unused_value")
pub impl ToLua for Int64 with fn to_lua(self) -> Value {
  @core.VInt(self)
}

///|
#warnings("-unused_value")
pub impl ToLua for Double with fn to_lua(self) -> Value {
  @core.VNum(self)
}

///|
/// Text becomes a Lua string holding its UTF-8 bytes.
#warnings("-unused_value")
pub impl ToLua for String with fn to_lua(self) -> Value {
  Value::text(self)
}

///|
/// Bytes become a Lua string holding exactly those bytes.
#warnings("-unused_value")
pub impl ToLua for Bytes with fn to_lua(self) -> Value {
  @core.VStr(@core.LStr::of_bytes(self))
}

///|
#warnings("-unused_value")
pub impl ToLua for Table with fn to_lua(self) -> Value {
  @core.VTable(self)
}

///|
/// `None` is `nil`, which is what a host returning "nothing" means in Lua.
#warnings("-unused_value")
pub impl[T : ToLua] ToLua for T? with fn to_lua(self) -> Value {
  match self {
    None => @core.VNil
    Some(v) => v.to_lua()
  }
}

///|
/// An array becomes a sequence: `t[1]` is the first item, `#t` is its length.
#warnings("-unused_value")
pub impl[T : ToLua] ToLua for Array[T] with fn to_lua(self) -> Value {
  let t = @core.LTable::new()
  let mut i = 1L
  for v in self {
    t.set_int(i, v.to_lua())
    i = i + 1L
  }
  @core.VTable(t)
}

///|
/// A map becomes a table whose keys are the converted keys, so
/// `Map[String, Int]` is readable in Lua as `t["name"]`.
#warnings("-unused_value")
pub impl[K : ToLua, V : ToLua] ToLua for Map[K, V] with fn to_lua(self) -> Value {
  let t = @core.LTable::new()
  for k, v in self {
    let _ = t.set(k.to_lua(), v.to_lua())
  }
  @core.VTable(t)
}

///|
/// A fresh, empty table for filling in from the host.
pub fn new_table() -> Table {
  @core.LTable::new()
}
