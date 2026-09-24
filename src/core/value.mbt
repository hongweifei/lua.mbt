// The Lua value model.

///|
pub(all) struct LStr {
  bytes : Bytes
  hash : Int
  // Identity of the string object, mirroring the address of a `TString`;
  // interning makes equal constants share one id.
  id : Int
}

///|
pub fn LStr::of_string(s : String) -> LStr {
  LStr::of_bytes(bytes_of(s))
}

///|
/// Strings shorter than the reference implementation's `LUAI_MAXSHORTLEN`
/// are interned, so that equal short strings are the same object.
let str_intern_limit : Int = 40

///|
let str_intern_table : Map[Bytes, LStr] = Map([])

///|
/// The bytes every string created so far occupies.  It only ever grows: the
/// collector reads it to tell how much a program has allocated since the last
/// cycle, which is the part of `collectgarbage("count")` that garbage
/// contributes while it is still around.  The object clock in `objects.mbt`
/// measures the same thing for everything else, and the collector reads both
/// together.
let str_allocated_bytes : Ref[Int] = Ref(0)

///|
pub fn LStr::of_bytes(b : Bytes) -> LStr {
  // Only a string that is actually made counts: equal short strings share one
  // object, and charging for each lookup would make a program that keeps
  // naming the same string look like it allocates without end.
  if b.length() < str_intern_limit {
    match str_intern_table.get(b) {
      Some(s) => s
      None => {
        str_allocated_bytes.val = str_allocated_bytes.val + 24 + b.length()
        let s : LStr = { bytes: b, hash: b.hash(), id: next_object_id(), }
        str_intern_table[b] = s
        s
      }
    }
  } else {
    str_allocated_bytes.val = str_allocated_bytes.val + 24 + b.length()
    { bytes: b, hash: b.hash(), id: next_object_id(), }
  }
}

///|
pub fn LStr::empty() -> LStr {
  // The hash must be the one the contents produce, or equality against another
  // empty string would fail.
  LStr::of_bytes(Bytes::new(0))
}

///|
pub fn LStr::length(self : LStr) -> Int {
  self.bytes.length()
}

///|
pub fn LStr::byte_at(self : LStr, i : Int) -> Int {
  ubyte_at(self.bytes, i)
}

///|
/// The byte sequence itself.  Lua strings are never converted to text when
/// used as values, only when they are handed to the host.
pub fn LStr::data(self : LStr) -> Bytes {
  self.bytes
}

///|
pub fn LStr::is_empty(self : LStr) -> Bool {
  self.bytes.length() == 0
}

///|
pub fn LStr::sub(self : LStr, start : Int, len : Int) -> LStr {
  LStr::of_bytes(bytes_slice(self.bytes, start, len))
}

///|
pub fn LStr::concat(self : LStr, other : LStr) -> LStr {
  LStr::of_bytes(bytes_concat([self.bytes, other.bytes]))
}

///|
/// Equality is by content.  A mismatching hash is a definitive answer, so the
/// byte comparison only runs for strings that hash alike.
pub fn LStr::equal(self : LStr, other : LStr) -> Bool {
  self.hash == other.hash &&
  self.bytes.length() == other.bytes.length() &&
  self.bytes == other.bytes
}

///|
pub impl Hash for LStr with fn hash_combine(self, hasher) {
  hasher.combine_int(self.hash)
}

///|
pub impl Eq for LStr with fn equal(self, other) {
  self.equal(other)
}

///|
pub impl Compare for LStr with fn compare(self, other) {
  Bytes::lexical_compare(self.bytes, other.bytes)
}

///|
pub impl Show for LStr with fn output(self, logger) {
  logger.write_string(text_of(self.bytes))
}

///|----------------------------------------------------------------
/// Global identity counter.
///
/// Tables, closures, userdata and threads are compared by identity, which the
/// hash part of a table expresses with a small integer stamped on the object at
/// creation time.

///|
pub let obj_counter : Ref[Int] = Ref(0)

///|
pub fn next_object_id() -> Int {
  obj_counter.val = obj_counter.val + 1
  obj_counter.val
}

///|----------------------------------------------------------------
/// Table keys.
///
/// The hash part of a table is keyed by this normalised form.  A float that
/// happens to hold an integral value is keyed as an integer so that `t[1]` and
/// `t[1.0]` denote the same slot, and `-0.0` is normalised to `0.0`.  NaN and
/// nil are rejected before a key is built.

///|
pub(all) enum Key {
  KInt(Int64)
  KNum(UInt64)
  KStr(LStr)
  KBool(Bool)
  /// A table, function, userdata or thread, keyed by its identity.  The value
  /// itself is kept so that `next` can hand the key back.
  KObj(Value)
  KNil
  KEmpty
}

///|
/// The identity of an object used as a table key.
pub fn Value::obj_id(self : Value) -> Int {
  match self {
    VTable(t) => t.id
    VFunc(f) => f.id
    VBuiltin(b) => b.id
    VUserData(u) => u.id
    VThread(t) => t.id
    _ => 0
  }
}

///|
pub impl Hash for Key with fn hash_combine(self, hasher) {
  match self {
    KInt(i) => hasher.combine_int64(i)
    KNum(bits) => hasher.combine_uint64(bits)
    KStr(s) => hasher.combine_int(s.hash)
    KBool(b) => hasher.combine_bool(b)
    KObj(v) => hasher.combine_int(v.obj_id())
    KNil => hasher.combine_int(0x5EED_0000)
    KEmpty => hasher.combine_int(0x5EED_0001)
  }
}

///|
pub impl Eq for Key with fn equal(self, other) {
  match (self, other) {
    (KInt(a), KInt(b)) => a == b
    (KNum(a), KNum(b)) => a == b
    (KStr(a), KStr(b)) => a.equal(b)
    (KBool(a), KBool(b)) => a == b
    (KObj(a), KObj(b)) => a.obj_id() == b.obj_id()
    (KNil, KNil) => true
    (KEmpty, KEmpty) => true
    _ => false
  }
}

///|
pub fn key_hash(k : Key) -> Int {
  let h = Hasher::Hasher()
  h.combine(k)
  h.finalize()
}

///|
/// The empty list of values that a frame with no varargs holds.  Nothing ever
/// writes to it -- a frame's varargs are only touched for a vararg prototype,
/// and `debug.setlocal` only reaches one that is longer than the index it is
/// given -- so a single shared list saves an allocation on every call.
pub let no_values : Array[Value] = []

///|----------------------------------------------------------------
/// Lua values.

///|
#valtype
pub(all) enum Value {
  VNil
  VBool(Bool)
  VInt(Int64)
  VNum(Double)
  VStr(LStr)
  VTable(LTable)
  VFunc(LClosure)
  VBuiltin(LBuiltin)
  VThread(LThread)
  VUserData(LUserData)
}

///|
pub fn Value::is_nil(self : Value) -> Bool {
  match self {
    VNil => true
    _ => false
  }
}

///|
pub fn Value::is_truthy(self : Value) -> Bool {
  match self {
    VNil => false
    VBool(b) => b
    _ => true
  }
}

///|
pub fn Value::is_number(self : Value) -> Bool {
  match self {
    VInt(_) | VNum(_) => true
    _ => false
  }
}

///|
pub fn Value::type_name(self : Value) -> String {
  match self {
    VNil => "nil"
    VBool(_) => "boolean"
    VInt(_) | VNum(_) => "number"
    VStr(_) => "string"
    VTable(_) => "table"
    VFunc(_) | VBuiltin(_) => "function"
    VThread(_) => "thread"
    // A light userdata reports "userdata", the same as a full one: the two are
    // separate Lua types but share a name in `luaT_typenames_`.  Only the
    // *argument* errors tell them apart (`type_error_name`).
    VUserData(_) => "userdata"
  }
}

///|
/// Identity of an object value, for `__eq` bookkeeping and for registry keys.
pub fn Value::object_id(self : Value) -> Int {
  match self {
    VTable(t) => t.id
    VFunc(f) => f.id
    VBuiltin(b) => b.id
    VUserData(u) => u.id
    VThread(t) => t.id
    VStr(s) => s.id
    _ => 0
  }
}

///|
/// Raw equality (`==` without metamethods).  Numbers compare across subtypes,
/// strings by content, everything else by identity.
pub fn Value::raw_equal(self : Value, other : Value) -> Bool {
  match (self, other) {
    (VNil, VNil) => true
    (VBool(a), VBool(b)) => a == b
    (VInt(a), VInt(b)) => a == b
    (VNum(a), VNum(b)) => a == b
    (VInt(a), VNum(b)) => int_equals_float(a, b)
    (VNum(a), VInt(b)) => int_equals_float(b, a)
    (VStr(a), VStr(b)) => a.equal(b)
    (VTable(a), VTable(b)) => a.id == b.id
    (VFunc(a), VFunc(b)) => a.id == b.id
    (VBuiltin(a), VBuiltin(b)) => a.id == b.id
    (VUserData(a), VUserData(b)) => a.id == b.id
    (VThread(a), VThread(b)) => a.id == b.id
    _ => false
  }
}

///|----------------------------------------------------------------
/// Numeric conversions.
///
/// These mirror the coercions Lua performs: an integer and a float are equal
/// when the float denotes the same mathematical value; a float with an integral
/// value converts to an exact integer when it fits in 64 bits.

///|
pub let two_pow_63 : Double = 9223372036854775808.0

///|
pub let two_pow_63_neg : Double = -9223372036854775808.0

///|
/// True when a float holds an integral value representable as an Int64.
pub fn float_is_int64(d : Double) -> Bool {
  !d.is_nan() && d >= two_pow_63_neg && d < two_pow_63 && d == d.floor()
}

///|
/// Converts an integral float to Int64.  The caller must have checked
/// `float_is_int64`.
pub fn float_to_int64(d : Double) -> Int64 {
  d.to_int64()
}

///|
/// A float as the value to hand back to Lua: an integer when it holds one, a
/// float otherwise.  This is the reference's `pushnumint`, which is what makes
/// `math.floor(3.5)` and the integral part of `math.modf` an integer while
/// `math.floor(math.huge)` stays a float.
pub fn num_int(d : Double) -> Value {
  if float_is_int64(d) {
    VInt(float_to_int64(d))
  } else {
    VNum(d)
  }
}

///|
/// `a == b` where one side is an integer and the other a float, using the exact
/// mathematical comparison rather than a lossy conversion.
pub fn int_equals_float(a : Int64, b : Double) -> Bool {
  if !float_is_int64(b) {
    return false
  }
  a == b.to_int64()
}

///|
/// Whether `a` survives a conversion to a double unchanged, which lets an
/// integer and a float be compared as floats.
pub fn int_fits_double(a : Int64) -> Bool {
  let limit = 1L << 53
  a >= -limit && a <= limit
}

///|
/// Rounds a float away from zero, keeping the result inside the integer range.
pub fn float_ceil_to_int64(d : Double) -> Int64? {
  if d >= two_pow_63_neg && d < two_pow_63 {
    Some(d.ceil().to_int64())
  } else {
    None
  }
}

///|
pub fn float_floor_to_int64(d : Double) -> Int64? {
  if d >= two_pow_63_neg && d < two_pow_63 {
    Some(d.floor().to_int64())
  } else {
    None
  }
}

///|
/// `i < f` for an integer and a float.  A float that is out of the integer
/// range is bigger or smaller than every integer, which is what the fallback
/// reports.
pub fn int_lt_float(i : Int64, f : Double) -> Bool {
  if int_fits_double(i) {
    i.to_double() < f
  } else {
    match float_ceil_to_int64(f) {
      Some(fi) => i < fi
      None => f > 0.0
    }
  }
}

///|
pub fn int_le_float(i : Int64, f : Double) -> Bool {
  if int_fits_double(i) {
    i.to_double() <= f
  } else {
    match float_floor_to_int64(f) {
      Some(fi) => i <= fi
      None => f > 0.0
    }
  }
}

///|
pub fn float_lt_int(f : Double, i : Int64) -> Bool {
  if int_fits_double(i) {
    f < i.to_double()
  } else {
    match float_floor_to_int64(f) {
      Some(fi) => fi < i
      None => f < 0.0
    }
  }
}

///|
pub fn float_le_int(f : Double, i : Int64) -> Bool {
  if int_fits_double(i) {
    f <= i.to_double()
  } else {
    match float_ceil_to_int64(f) {
      Some(fi) => fi <= i
      None => f < 0.0
    }
  }
}

///|
/// Converts a value to an Int64 if it denotes an integral number.
pub fn value_to_int64(v : Value) -> IntConv {
  match v {
    VInt(i) => ConvInt(i)
    VNum(d) =>
      if float_is_int64(d) {
        ConvInt(float_to_int64(d))
      } else {
        ConvNoInt
      }
    _ => ConvNoInt
  }
}

///|
/// Converts a value to a Double if it is a number.
pub fn value_to_double(v : Value) -> NumConv {
  match v {
    VInt(i) => ConvNum(i.to_double())
    VNum(d) => ConvNum(d)
    _ => ConvNoNum
  }
}

///|----------------------------------------------------------------
/// Coercion results
///
/// A number is asked for once per operand of every arithmetic and comparison
/// instruction, so the answer must not cost an allocation.  `Option` boxes its
/// payload on the native backend, which would put a heap object in the
/// interpreter's inner loop; these are `#valtype`, so the answer stays in
/// registers.

///|
/// A value coerced to an integer: an integer itself, or a float that holds one.
#valtype
pub(all) enum IntConv {
  ConvInt(Int64)
  /// A number that is not an integer, or no number at all.  A caller tells the
  /// two apart by asking `is_number` again, which happens only on the path that
  /// reports the failure.
  ConvNoInt
}

///|
/// A value coerced to a float.
#valtype
pub(all) enum NumConv {
  ConvNum(Double)
  ConvNoNum
}
