// White-box tests for the hash part's integer probe.

///|
/// The hash part finds an integer key two ways: `probe_int` compares the raw
/// `Int64`, `probe` compares a built `Key`.  They must agree on every slot they
/// visit, including the cleared ones a delete left behind, or a table would hold
/// the same key twice.
test "the integer probe agrees with the keyed one" {
  let t = LTable::new()
  for i = 1; i <= 40; i = i + 1 {
    t.set_int(i.to_int64(), VInt(i.to_int64()))
  }
  for i = 1; i <= 40; i = i + 3 {
    t.set_int(i.to_int64(), VNil)
  }
  for i in [-5L, -1L, 0L, 41L, 64L, 65L, 1000L, -1000L, 0x7FFFFFFFL] {
    t.set_int(i, VInt(i))
  }
  // Clearing a hash-part key leaves its key in the slot, which is what a
  // traversal resumed with that key depends on.
  t.set_int(64L, VNil)
  for i = -6L; i <= 70L; i = i + 1 {
    assert_eq(t.probe_int(i, false), t.probe(KInt(i), false))
    assert_eq(t.probe_int(i, true), t.probe(KInt(i), true))
    assert_eq(t.hash_get_int(i).is_nil(), t.hash_get(KInt(i)).is_nil())
  }
  assert_true(t.get_int(64L).is_nil())
  assert_true(!(t.next(VInt(64L)) is NextBadKey))
}

///|
/// Writing through the integer entry points and reading through the general ones
/// (and the other way round) is one table.
test "the integer entry points agree with the general ones" {
  let t = LTable::new()
  for i = 1; i <= 30; i = i + 1 {
    ignore(t.set(VInt(i.to_int64()), VInt((i * 2).to_int64())))
  }
  for i = -30L; i <= 0L; i = i + 1 {
    ignore(t.set(VInt(i), VInt(i * 3L)))
  }
  for i = -35L; i <= 35L; i = i + 1 {
    assert_eq(t.get_int(i).as_integer(), t.get(VInt(i)).as_integer())
  }
  t.set_int(-7L, VInt(700L))
  assert_eq(t.get(VInt(-7L)).as_integer(), Some(700L))
  ignore(t.set(VInt(-8L), VInt(800L)))
  assert_eq(t.get_int(-8L).as_integer(), Some(800L))
  t.set_int(-7L, VNil)
  assert_true(t.get(VInt(-7L)).is_nil())
  assert_true(!(t.next(VInt(-7L)) is NextBadKey))
}
