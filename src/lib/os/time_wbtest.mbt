// White-box tests for the half of `os.time` that needs no host clock: the
// structure the host reports back is nine numbers, and turning those into table
// fields is the reference's rule (`setallfields`), not the C library's.

///|
/// What a field of the table holds, spelled out: a test that compared values
/// would have to say which `Value` it expects, and here the answer is only ever
/// an integer, a boolean, or nothing.
fn written(t : @core.LTable, key : String) -> String {
  match t.get_str(key) {
    @core.VInt(i) => i.to_string()
    @core.VBool(true) => "true"
    @core.VBool(false) => "false"
    @core.VNil => "nil"
    v => "other:" + v.type_name()
  }
}

///|
test "the normalised structure goes back under Lua's names" {
  let state = @core.lua_state_new()
  let t = @core.LTable::new()
  // tm_year, tm_mon, tm_mday, tm_hour, tm_min, tm_sec, tm_yday, tm_wday, tm_isdst
  set_all_fields(state, t, [125L, 0L, 1L, 12L, 0L, 0L, 0L, 3L, 0L])
  assert_eq(written(t, "year"), "2025")
  assert_eq(written(t, "month"), "1")
  assert_eq(written(t, "day"), "1")
  assert_eq(written(t, "hour"), "12")
  assert_eq(written(t, "min"), "0")
  assert_eq(written(t, "sec"), "0")
  // Both derived fields are zero-based in C and one-based in Lua.
  assert_eq(written(t, "yday"), "1")
  assert_eq(written(t, "wday"), "4")
  assert_eq(written(t, "isdst"), "false")
  // `day` is the Lua name; the member it came from never appears.
  assert_eq(written(t, "mday"), "nil")
  assert_eq(written(t, "mon"), "nil")
}

///|
test "an undefined daylight-saving flag is not written at all" {
  let state = @core.lua_state_new()
  let t = @core.LTable::new()
  // A `tm_year` below zero is a year before 1900, and the offset goes back on
  // the same way; `tm_isdst` of -1 means the host did not answer.
  set_all_fields(state, t, [-1L, 11L, 31L, 12L, 0L, 0L, 364L, 3L, -1L])
  assert_eq(written(t, "year"), "1899")
  assert_eq(written(t, "month"), "12")
  assert_eq(written(t, "day"), "31")
  assert_eq(written(t, "yday"), "365")
  assert_eq(written(t, "isdst"), "nil")
}

///|
test "the structure the host reports is nine numbers" {
  // The widths the reader and the C writer agree on: nothing in `stub.c` was
  // filled in, so every field reads as zero and there are exactly nine of them.
  // Their *encoding* is pinned from the Lua side, where a pre-1900 year arrives
  // as a negative `tm_year` and a wrong byte order would turn it into nonsense.
  let tm = Bytes::new(tm_field_count * 8)
  assert_eq(tm_values(tm), [0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L])
}
