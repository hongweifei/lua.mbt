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

///|----------------------------------------------------------------
/// Reading Lua values back as MoonBit ones.
///
/// `ToLua` moves data in; this moves it out, with the same names the language
/// uses.  A reader answers `Option`, because a host usually has several kinds to
/// try and `None` says "not this one" without a message -- `Lua::value_as` is the
/// variant that reports it, and asks the type how, through `expected_and_got`.
///
/// The rules are the interpreter's own readers (`as_integer` is `math.tointeger`,
/// `as_bytes` is a string's exact bytes), so a host and a script cannot disagree
/// about what a value means.  A reader names its type in the **annotation**, not
/// at the call: `let n : Int64? = read_lua(v)`, or `FromLua::from_lua(v)` written
/// out.  Calling it as `Int64::from_lua(v)` is not a thing this language resolves.

///|----------------------------------------------------------------

///|
/// Where reading a container went wrong: the entry that is not of the item type.
/// A failure inside a table is about that entry, and a complaint that said "the
/// table" would name a value that is exactly what was asked for.
priv enum ReadFail {
  BadKey(Value)
  BadItem(Value)
}

///|
/// A value Lua has that a host wants as a MoonBit one.  Implemented for the
/// scalars, for `Bytes`, for `Table` and `Value`, for `Option` (a `nil` is
/// `None`), for `Array` (a table read as a sequence) and for `Map[String, T]`.
pub trait FromLua {
  fn from_lua(Value) -> Self?

  /// The complaint for a value that is not this kind: the kind wanted and the
  /// value to name as what came instead -- the two halves of "number expected,
  /// got string".  A container holding an item of the wrong kind names the item.
  fn expected_and_got(Value) -> (String, Value)
}

///|
#warnings("-unused_value")
pub impl FromLua for Value with fn from_lua(v : Value) -> Value? {
  Some(v)
}

///|
#warnings("-unused_value")
pub impl FromLua for Value with fn expected_and_got(v : Value) -> (
  String,
  Value,
) {
  ("value", v)
}

///|
/// Only a Lua `boolean` reads as a `Bool`.  Truthiness is a different question,
/// and `Lua::eval_bool` is where it lives.
#warnings("-unused_value")
pub impl FromLua for Bool with fn from_lua(v : Value) -> Bool? {
  match v {
    @core.VBool(b) => Some(b)
    _ => None
  }
}

///|
#warnings("-unused_value")
pub impl FromLua for Bool with fn expected_and_got(v : Value) -> (String, Value) {
  ("boolean", v)
}

///|
/// An integer, as `math.tointeger` reads one: an integer, a float holding one, or
/// a string spelling one.  A value too big for MoonBit's `Int` reads as nothing
/// rather than wrapping.
#warnings("-unused_value")
pub impl FromLua for Int with fn from_lua(v : Value) -> Int? {
  match v.as_integer() {
    Some(i) => {
      let as_int = i.to_int()
      if as_int.to_int64() == i {
        Some(as_int)
      } else {
        None
      }
    }
    None => None
  }
}

///|
#warnings("-unused_value")
pub impl FromLua for Int with fn expected_and_got(v : Value) -> (String, Value) {
  ("number", v)
}

///|
#warnings("-unused_value")
pub impl FromLua for Int64 with fn from_lua(v : Value) -> Int64? {
  v.as_integer()
}

///|
#warnings("-unused_value")
pub impl FromLua for Int64 with fn expected_and_got(v : Value) -> (
  String,
  Value,
) {
  ("number", v)
}

///|
/// A number as a float.  An integer widens, and so does a string that spells a
/// number; past 2^53 an integer loses precision in the widening, as it does in
/// Lua.
#warnings("-unused_value")
pub impl FromLua for Double with fn from_lua(v : Value) -> Double? {
  v.as_double()
}

///|
#warnings("-unused_value")
pub impl FromLua for Double with fn expected_and_got(v : Value) -> (
  String,
  Value,
) {
  ("number", v)
}

///|
/// Text from a Lua string.  A Lua string is bytes, so bytes that are not UTF-8
/// come back replaced; `Bytes` is the exact reader.
#warnings("-unused_value")
pub impl FromLua for String with fn from_lua(v : Value) -> String? {
  v.as_text()
}

///|
#warnings("-unused_value")
pub impl FromLua for String with fn expected_and_got(v : Value) -> (
  String,
  Value,
) {
  ("string", v)
}

///|
/// The bytes of a Lua string, exactly.  A number does not read as a string,
/// because `lua_tostring` rewrites the stack to make one and a reader here must
/// not change what Lua sees.
#warnings("-unused_value")
pub impl FromLua for Bytes with fn from_lua(v : Value) -> Bytes? {
  v.as_bytes()
}

///|
#warnings("-unused_value")
pub impl FromLua for Bytes with fn expected_and_got(v : Value) -> (
  String,
  Value,
) {
  ("string", v)
}

///|
#warnings("-unused_value")
pub impl FromLua for Table with fn from_lua(v : Value) -> Table? {
  match v {
    @core.VTable(t) => Some(t)
    _ => None
  }
}

///|
#warnings("-unused_value")
pub impl FromLua for Table with fn expected_and_got(v : Value) -> (
  String,
  Value,
) {
  ("table", v)
}

///|
/// `nil` is `None`.  A value of some other wrong type also reads as `None`, which
/// is why a host that must tell the two apart asks `v.is_nil()` itself.
#warnings("-unused_value")
pub impl[T : FromLua] FromLua for T? with fn from_lua(v : Value) -> T?? {
  if v.is_nil() {
    Some(None)
  } else {
    Some(T::from_lua(v))
  }
}

///|
#warnings("-unused_value")
pub impl[T : FromLua] FromLua for T? with fn expected_and_got(v : Value) -> (
  String,
  Value,
) {
  T::expected_and_got(v)
}

///|
/// The items of a table up to its first absent field, or the first item that is
/// not a `T` -- the value a complaint should name.
fn[T : FromLua] read_items(t : Table) -> Result[Array[T], Value] {
  let out : Array[T] = []
  let mut i = 1L
  for ;; {
    let item = t.get_int(i)
    if item.is_nil() {
      break
    }
    let x : T? = read_lua(item)
    match x {
      Some(v) => out.push(v)
      None => return Err(item)
    }
    i = i + 1L
  }
  Ok(out)
}

///|
/// A table read as a sequence: `t[1]`, `t[2]`, ... up to the first absent field,
/// the way `ipairs` and `table.unpack` walk it.  Every item has to convert or the
/// whole read is nothing -- a half-read sequence is not a thing a host can use.
/// A table with a hole stops at the hole.
#warnings("-unused_value")
pub impl[T : FromLua] FromLua for Array[T] with fn from_lua(v : Value) -> Array[
  T,
]? {
  match v {
    @core.VTable(t) =>
      match read_items(t) {
        Ok(xs) => Some(xs)
        Err(_) => None
      }
    _ => None
  }
}

///|
#warnings("-unused_value")
pub impl[T : FromLua] FromLua for Array[T] with fn expected_and_got(v : Value) -> (
  String,
  Value,
) {
  match v {
    @core.VTable(t) => {
      let read : Result[Array[T], Value] = read_items(t)
      match read {
        Err(item) => T::expected_and_got(item)
        Ok(_) => ("table", v)
      }
    }
    _ => ("table", v)
  }
}

///|
/// A table's own fields with string keys -- the same walk `next` makes, so no
/// `__index` is consulted -- or the first entry that is not one.
fn[V : FromLua] read_str_fields(t : Table) -> Result[Map[String, V], ReadFail] {
  let out : Map[String, V] = Map([])
  let mut key = @core.VNil
  for ;; {
    match t.next(key) {
      @core.NextPair(k, item) => {
        let name : String? = read_lua(k)
        let value : V? = read_lua(item)
        match (name, value) {
          (Some(n), Some(v)) => out[n] = v
          (None, _) => return Err(BadKey(k))
          (Some(_), None) => return Err(BadItem(item))
        }
        key = k
      }
      @core.NextEnd | @core.NextBadKey => break
    }
  }
  Ok(out)
}

///|
/// A table read as a map over its *own* fields.  Keys are strings, which is what
/// a Lua table's named fields are; a table numbered from 1 reads as `Array`.
/// Every entry has to convert, or the whole read is nothing.
#warnings("-unused_value")
pub impl[V : FromLua] FromLua for Map[String, V] with fn from_lua(v : Value) -> Map[
  String,
  V,
]? {
  match v {
    @core.VTable(t) =>
      match read_str_fields(t) {
        Ok(m) => Some(m)
        Err(_) => None
      }
    _ => None
  }
}

///|
#warnings("-unused_value")
pub impl[V : FromLua] FromLua for Map[String, V] with fn expected_and_got(
  v : Value,
) -> (String, Value) {
  match v {
    @core.VTable(t) => {
      let read : Result[Map[String, V], ReadFail] = read_str_fields(t)
      match read {
        Err(BadKey(k)) => ("string", k)
        Err(BadItem(item)) => V::expected_and_got(item)
        Ok(_) => ("table", v)
      }
    }
    _ => ("table", v)
  }
}

///|
/// A value of a type the host picks, written so the type comes from the
/// annotation: `let items : Array[String]? = read_lua(v)`.  The rules are the
/// language's own, which is what this test is pinning.
///
/// ```mbt check
/// test "reading rules, in both directions" {
///   let lua = Lua::new()
///   // A string spelling a number reads as one, because `math.tointeger` does.
///   let from_text : Int64? = read_lua(lua.eval("return '42'").unwrap())
///   assert_eq(from_text, Some(42L))
///   // A number does not read as text, though Lua's `tostring` would make one.
///   let number_as_text : String? = read_lua(lua.eval("return 42").unwrap())
///   assert_eq(number_as_text, None)
///   assert_eq(lua.show(lua.eval("return 42").unwrap()), "42")
///   // An integer too wide for MoonBit's `Int` is nothing rather than a wrap.
///   let too_wide : Int? = read_lua(lua.eval("return math.maxinteger").unwrap())
///   assert_eq(too_wide, None)
///   let fits : Int? = read_lua(lua.eval("return 42").unwrap())
///   assert_eq(fits, Some(42))
///   // A `boolean` reads strictly; Lua's *truth* is `Lua::eval_bool`'s question.
///   let zero_as_bool : Bool? = read_lua(lua.eval("return 0").unwrap())
///   assert_eq(zero_as_bool, None)
///   assert_eq(lua.eval_bool("return 0").unwrap(), true)
///   // Compound types name themselves the same way.
///   let items : Array[Int64]? = read_lua(lua.eval("return {7, 8}").unwrap())
///   assert_eq(items, Some([7L, 8L]))
///   let cfg : Map[String, Int64]? = read_lua(
///     lua.eval("return {a = 1, b = 2}").unwrap(),
///   )
///   assert_eq(cfg, Some(Map([("a", 1L), ("b", 2L)])))
///   // A table is a sequence only up to its first absent field.
///   let holed : Array[Int64]? = read_lua(lua.eval("return {1, nil, 3}").unwrap())
///   assert_eq(holed, Some([1L]))
///   // A `nil` is `None`, and so is a wrong type -- `is_nil` tells them apart.
///   let maybe : Int64? = read_lua(lua.eval("return nil").unwrap())
///   assert_eq(maybe, None)
/// }
/// ```
pub fn[T : FromLua] read_lua(v : Value) -> T? {
  T::from_lua(v)
}

///|
/// The fields of a table, in the order `next` gives them -- the same walk `pairs`
/// makes over the table's own entries, without consulting a metatable.
pub fn table_entries(t : Table) -> Array[(Value, Value)] {
  let out : Array[(Value, Value)] = []
  let mut key = @core.VNil
  for ;; {
    match t.next(key) {
      @core.NextPair(k, v) => {
        out.push((k, v))
        key = k
      }
      @core.NextEnd | @core.NextBadKey => break
    }
  }
  out
}

///|
/// A table read as a sequence of values, `t[1]` up to the first absent field.
/// This is the `Array[Value]` of `FromLua` without the conversion, for a host
/// that wants to look at each item itself.
pub fn table_sequence(t : Table) -> Array[Value] {
  let out : Array[Value] = []
  let mut i = 1L
  for ;; {
    let v = t.get_int(i)
    if v.is_nil() {
      break
    }
    out.push(v)
    i = i + 1L
  }
  out
}
