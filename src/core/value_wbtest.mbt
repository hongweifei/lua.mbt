// White-box tests for the key layer.

///|
/// A key's slot comes from `key_hash`, and for a string that is the content hash
/// `LStr` already carries.  Two equal strings that are *not* the same object (a
/// long enough string is not interned) must land in the same slot, or a table
/// would hold the same key twice.
test "equal strings that are not one object are one key" {
  let long = "0123456789012345678901234567890123456789012345678901234567890123456789"
  let a = LStr::of_bytes(bytes_of(long))
  let b = LStr::of_bytes(bytes_of(long))
  assert_true(a.equal(b))
  assert_eq(key_hash(KStr(a)), key_hash(KStr(b)))

  let t = LTable::new()
  t.set_str(long, VInt(7L))
  assert_eq(t.get_lstr(b).as_integer(), Some(7L))
  assert_eq(t.get_lstr(a).as_integer(), Some(7L))
}
