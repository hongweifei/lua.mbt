// End to end checks driven from MoonBit.

///|
///Smoke tests exercising the interpreter end to end.
test "runs an empty chunk" {
  let state = create()
  let (ok, _) = run_string(state, "", "=test")
  assert_true(ok)
}

///|
test "evaluates arithmetic" {
  let state = create()
  let (ok, vals) = run_string(state, "return 1 + 2 * 3", "=test")
  assert_true(ok)
  assert_eq(vals.length(), 1)
  match vals[0] {
    @core.VInt(v) => assert_eq(v, 7L)
    _ => fail("expected an integer")
  }
}

///|
test "concatenates and compares" {
  let state = create()
  let (ok, vals) = run_string(state, "return 'a' .. 'b' .. 1, 3 < 5", "=test")
  assert_true(ok)
  assert_eq(vals.length(), 2)
  match (vals[0], vals[1]) {
    (@core.VStr(s), @core.VBool(b)) => {
      assert_true(s.data() == @core.bytes_of("ab1"))
      assert_true(b)
    }
    _ => fail("unexpected results")
  }
}

///|
/// Filling a table without end is refused with the reference's message once the
/// interpreter's own budget is spent, instead of taking the host down with it.
/// The budget is lowered here so that the test does not have to allocate a
/// gigabyte to see it.
test "refuses to grow past the memory budget" {
  let state = create()
  state.memory_limit = 1 << 20
  let (ok, vals) = run_string(
    state, "local a = {} for i = 1, math.huge do a[i] = i end", "=test",
  )
  assert_true(!ok)
  match vals[0] {
    @core.VStr(s) =>
      assert_true(s.data() == @core.bytes_of("not enough memory"))
    _ => fail("expected the budget to refuse")
  }
  // The refusal is an ordinary error: the state still runs afterwards.
  let (ok2, vals2) = run_string(state, "return 1 + 1", "=test")
  assert_true(ok2)
  match vals2[0] {
    @core.VInt(v) => assert_eq(v, 2L)
    _ => fail("expected an integer")
  }
}
