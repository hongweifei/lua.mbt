// Tables: access, length, traversal, metatable.

///|
pub(all) struct LTable {
  arr : Array[Value]
  mut hkeys : Array[Key]
  mut hvals : Array[Value]
  mut hlive : Int
  mut hdead : Int
  mut meta : LTable?
  id : Int
  /// The collection cycle that last reached this table.  A counter rather than
  /// a flag, because the host runtime's reference counting is what reclaims
  /// memory: nothing sweeps the mark bits, so a stale `true` would have to be
  /// cleared by hand, while a stale epoch simply compares unequal.
  mut mark_epoch : Int
}

///|
pub fn LTable::new() -> LTable {
  // A table costs its header plus what its slots grow by later (charged where
  // they are stored).
  charge_object_bytes(56)
  {
    arr: [],
    hkeys: [],
    hvals: [],
    hlive: 0,
    hdead: 0,
    meta: None,
    id: next_object_id(),
    mark_epoch: 0,
  }
}

///|----------------------------------------------------------------
/// Key normalisation

///|----------------------------------------------------------------

///|
/// Builds the hash key for a value.  `None` means the value cannot be used as a
/// key (nil, or NaN).
pub fn key_of_value(v : Value) -> Key? {
  match v {
    VNil => None
    VBool(b) => Some(KBool(b))
    VInt(i) => Some(KInt(i))
    VNum(d) =>
      if d.is_nan() {
        None
      } else {
        let normalised = if d == 0.0 { 0.0 } else { d }
        if float_is_int64(normalised) {
          Some(KInt(float_to_int64(normalised)))
        } else {
          Some(KNum(normalised.reinterpret_as_uint64()))
        }
      }
    VStr(s) => Some(KStr(s))
    VTable(_) | VFunc(_) | VBuiltin(_) | VUserData(_) | VThread(_) =>
      Some(KObj(v))
  }
}

///|
/// Builds the pool key for a constant.  Unlike a table key, `nil` and `NaN` are
/// valid here because a constant only has to be compared with itself.
pub fn const_key(v : Value) -> Key {
  match v {
    VNil => KNil
    VBool(b) => KBool(b)
    VInt(i) => KInt(i)
    VNum(d) => KNum(d.reinterpret_as_uint64())
    VStr(s) => KStr(s)
    _ => KNil
  }
}

///|----------------------------------------------------------------
/// Hash part internals

///|
/// Moves the integer keys `n+1`, `n+2`, ... from the hash part into the array
/// part while they are present in sequence.  Called after the array part grows
/// so that a table filled in an unusual order still ends up dense.
pub fn LTable::migrate_following(self : LTable) -> Unit {
  let mut n = self.arr.length()
  while true {
    let key = KInt((n + 1).to_int64())
    let i = self.hash_find(key)
    if i < 0 {
      return
    }
    self.arr.push(self.hvals[i])
    self.hvals[i] = VNil
    self.hlive = self.hlive - 1
    self.hdead = self.hdead + 1
    n = n + 1
  }
}

///|
pub fn LTable::get_int(self : LTable, i : Int64) -> Value {
  if i >= 1L && i <= self.arr.length().to_int64() {
    self.arr[(i - 1L).to_int()]
  } else {
    self.hash_get(KInt(i))
  }
}

///|----------------------------------------------------------------
/// Public accessors

///|----------------------------------------------------------------

///|
/// Raw read.  A nil or NaN key simply yields nil, like in the reference
/// implementation.
pub fn LTable::get(self : LTable, key : Value) -> Value {
  match key_of_value(key) {
    None => VNil
    Some(KInt(i)) => self.get_int(i)
    Some(k) => self.hash_get(k)
  }
}

///|
/// Raw read with a string key.
pub fn LTable::get_str(self : LTable, name : String) -> Value {
  self.hash_get(KStr(LStr::of_string(name)))
}

///|
/// Raw read with an integer key.
pub fn LTable::get_int_key(self : LTable, i : Int64) -> Value {
  self.get_int(i)
}

///|
/// Raw write.  Returns false when the key is neither a value nor a valid key
/// (nil or NaN), which the caller reports as an error.
pub fn LTable::set(self : LTable, key : Value, value : Value) -> Bool {
  match key_of_value(key) {
    None => false
    Some(KInt(i)) => {
      self.set_int(i, value)
      true
    }
    Some(k) => {
      if value.is_nil() {
        self.hash_delete(k)
      } else {
        self.hash_set(k, value)
      }
      true
    }
  }
}

///|
pub fn LTable::set_int(self : LTable, i : Int64, value : Value) -> Unit {
  let n = self.arr.length().to_int64()
  if i >= 1L && i <= n {
    self.arr[(i - 1L).to_int()] = value
    return
  }
  if i == n + 1L {
    if value.is_nil() {
      return
    }
    self.arr.push(value)
    self.migrate_following()
    return
  }
  let key = KInt(i)
  if value.is_nil() {
    self.hash_delete(key)
  } else {
    self.hash_set(key, value)
  }
}

///|
pub fn LTable::set_str(self : LTable, name : String, value : Value) -> Unit {
  self.set_key_keyed(KStr(LStr::of_string(name)), value)
}

///|
pub fn LTable::set_lstr(self : LTable, name : LStr, value : Value) -> Unit {
  self.set_key_keyed(KStr(name), value)
}

///|
pub fn LTable::set_key_keyed(self : LTable, key : Key, value : Value) -> Unit {
  if value.is_nil() {
    self.hash_delete(key)
  } else {
    self.hash_set(key, value)
  }
}

///|----------------------------------------------------------------
/// Length

///|
/// The `#` operator.  A border is any index `i` such that `t[i]` is not nil and
/// `t[i+1]` is nil; this finds one of them, preferring a border inside the array
/// part, exactly like `luaH_getn`.
pub fn LTable::raw_len(self : LTable) -> Int64 {
  let n = self.arr.length()
  if n > 0 && self.arr[n - 1].is_nil() {
    // There is a border inside the array part: binary search for it.
    let mut i = 0
    let mut j = n
    while j - i > 1 {
      let m = (i + j) / 2
      if self.arr[m - 1].is_nil() {
        j = m
      } else {
        i = m
      }
    }
    return i.to_int64()
  }
  // The array part is full: probe the hash part for the border, doubling the
  // * step until a nil is found, then binary searching the last interval.
  let mut i = n.to_int64()
  if self.hash_get(KInt(i + 1L)).is_nil() {
    return i
  }
  let mut step = 1L
  let mut j = i + 2L
  while !self.hash_get(KInt(j)).is_nil() {
    i = j
    if j > 0x4000000000000000L {
      break
    }
    step = step * 2L
    j = j + step
  }
  while j - i > 1L {
    let m = i + (j - i) / 2L
    if self.hash_get(KInt(m)).is_nil() {
      j = m
    } else {
      i = m
    }
  }
  i
}

///|
/// Traversal
pub(all) enum NextResult {
  NextPair(Value, Value)
  NextEnd
  NextBadKey
}

///|
/// Implements `next`.  `NextBadKey` is reported when the given key is not
/// present in the table.
pub fn LTable::next(self : LTable, key : Value) -> NextResult {
  match key {
    VNil => {
      // Restart: the array part first, then the hash part.
      let n = self.arr.length()
      let mut i = 0
      while i < n {
        if !self.arr[i].is_nil() {
          return NextPair(VInt((i + 1).to_int64()), self.arr[i])
        }
        i = i + 1
      }
      self.hash_next_from(0)
    }
    VInt(k) => {
      let n = self.arr.length().to_int64()
      if k >= 1L && k <= n {
        let mut i = k.to_int()
        while i < self.arr.length() {
          if !self.arr[i].is_nil() {
            return NextPair(VInt((i + 1).to_int64()), self.arr[i])
          }
          i = i + 1
        }
        return self.hash_next_from(0)
      }
      match self.hash_find_key(KInt(k)) {
        -1 => NextBadKey
        slot => self.hash_next_from(slot + 1)
      }
    }
    VNum(_) =>
      match key_of_value(key) {
        None => NextBadKey
        Some(KInt(i)) => self.next(VInt(i))
        Some(k) =>
          match self.hash_find_key(k) {
            -1 => NextBadKey
            slot => self.hash_next_from(slot + 1)
          }
      }
    _ =>
      match key_of_value(key) {
        None => NextBadKey
        Some(k) =>
          match self.hash_find_key(k) {
            -1 => NextBadKey
            slot => self.hash_next_from(slot + 1)
          }
      }
  }
}

///|
pub fn LTable::hash_next_from(self : LTable, from : Int) -> NextResult {
  let cap = self.hkeys.length()
  let mut i = from
  while i < cap {
    match self.hkeys[i] {
      KEmpty => ()
      k =>
        if !self.hvals[i].is_nil() {
          return NextPair(key_to_value(k), self.hvals[i])
        }
    }
    i = i + 1
  }
  NextEnd
}

///|
/// Rebuilds the original key value from a hash key.
pub fn key_to_value(k : Key) -> Value {
  match k {
    KInt(i) => VInt(i)
    KNum(bits) => VNum(bits.reinterpret_as_double())
    KStr(s) => VStr(s)
    KBool(b) => VBool(b)
    KObj(v) => v
    KNil => VNil
    KEmpty => VNil
  }
}

///|----------------------------------------------------------------
/// Metatable

///|----------------------------------------------------------------

///|
/// The metatable, ignoring `__metatable` hiding.  Use the VM level helper when
/// Lua code may observe the value.
pub fn LTable::metatable(self : LTable) -> LTable? {
  self.meta
}

///|
pub fn LTable::set_metatable(self : LTable, mt : LTable?) -> Unit {
  self.meta = mt
}

///|----------------------------------------------------------------
/// Misc

///|
/// Number of entries, counting the array part slots that are not nil.
pub fn LTable::count_entries(self : LTable) -> Int {
  let mut n = 0
  for v in self.arr {
    if !v.is_nil() {
      n = n + 1
    }
  }
  n + self.hlive
}

///|
pub fn LTable::array_size(self : LTable) -> Int {
  self.arr.length()
}

///|
/// The value form of this table.
pub fn LTable::as_value(self : LTable) -> Value {
  VTable(self)
}
