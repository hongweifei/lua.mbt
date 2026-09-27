// Checks on the host interface layer.

///|
///Smoke test for the host interface layer.
test "host layer: formatting" {
  let buf = Bytes::new(256)
  let fmt : Bytes = b"%.14g"
  let n = lua_mbt_fmt_double(buf, 256, fmt, 1.0 / 3.0)
  assert_true(buf.view(end=n).to_owned() == b"0.33333333333333")
  let fmt2 : Bytes = b"%lld"
  let n2 = lua_mbt_fmt_int64(buf, 256, fmt2, 42L)
  assert_true(buf.view(end=n2).to_owned() == b"42")
  let fmt3 : Bytes = b"%a"
  let n3 = lua_mbt_fmt_double(buf, 256, fmt3, 255.5)
  let hexrepr = buf.view(end=n3).to_owned()
  assert_true(hexrepr.length() > 4)
  assert_true(hexrepr.has_prefix(b"0x1"))
}

///|
test "host layer: streams and time" {
  let out = lua_mbt_stdout()
  assert_true(out != 0L)
  let _ = lua_mbt_fwrite(out, b"host layer ok\n", 14)
  let t = lua_mbt_time()
  assert_true(t > 1600000000L)
  let buf = Bytes::new(64)
  assert_eq(lua_mbt_tm_breakdown(t, 1, buf), 0)
  let sbuf = Bytes::new(64)
  let fmt : Bytes = b"%Y"
  let n = lua_mbt_strftime_time(sbuf, 64, fmt, t, 1)
  assert_true(n == 4)
}

///|
test "host layer: prng" {
  lua_mbt_rng_seed(12345UL, 67890UL)
  let a = lua_mbt_rng_next()
  let b = lua_mbt_rng_next()
  assert_true(a != b)
  lua_mbt_rng_seed(12345UL, 67890UL)
  assert_eq(lua_mbt_rng_next(), a)
}

///|
test "host layer: files" {
  let path : Bytes = b"_build_host_test.tmp"
  let f = lua_mbt_fopen(path, b"wb")
  assert_true(f != 0L)
  assert_eq(lua_mbt_fwrite(f, b"abcdefghij", 10), 10)
  assert_eq(lua_mbt_fclose(f), 0)
  let g = lua_mbt_fopen(path, b"rb")
  assert_true(g != 0L)
  let buf = Bytes::new(4)
  assert_eq(lua_mbt_fread(g, buf, 4), 4)
  assert_true(buf == b"abcd")
  assert_eq(lua_mbt_fseek(g, 0L, 2), 0.0)
  assert_eq(lua_mbt_ftell(g), 10L)
  assert_true(lua_mbt_feof(g) == 0)
  assert_eq(lua_mbt_fclose(g), 0)
  assert_eq(lua_mbt_remove(path), 0)
}

///|
/// A name outside the host's single byte encoding, given as UTF-8: it is
/// written, found again, renamed and removed, which is what makes a file whose
/// name is not ASCII usable at all.  The name is built from its bytes so that
/// the test does not depend on the encoding of this file.
test "host layer: a UTF-8 file name" {
  // "\u{4e2d}\u{6587}" -- 中文.
  let name : Bytes = b"_build_host_test_\xE4\xB8\xAD\xE6\x96\x87.tmp"
  let f = lua_mbt_fopen(name, b"wb")
  assert_true(f != 0L)
  assert_eq(lua_mbt_fwrite(f, b"x", 1), 1)
  assert_eq(lua_mbt_fclose(f), 0)
  // It is there under that name, and not under the bytes as they were typed in
  // the host's own encoding (which is a different name, if a name at all).
  let g = lua_mbt_fopen(name, b"rb")
  assert_true(g != 0L)
  assert_eq(lua_mbt_fclose(g), 0)
  let renamed : Bytes = b"_build_host_test_\xE4\xB8\xAD\xE6\x96\x87_2.tmp"
  assert_eq(lua_mbt_rename(name, renamed), 0)
  assert_true(lua_mbt_fopen(name, b"rb") == 0L)
  assert_eq(lua_mbt_remove(renamed), 0)
  // A name that is not UTF-8 still goes to the host as it is, so a name written
  // in the host's own encoding keeps working.  "\xD6\xD0\xCE\xC4" is 中文 in the
  // Chinese ANSI code page, and is not a UTF-8 sequence.
  let narrow : Bytes = b"_build_host_test_\xD6\xD0\xCE\xC4.tmp"
  let h = lua_mbt_fopen(narrow, b"wb")
  assert_true(h != 0L)
  assert_eq(lua_mbt_fclose(h), 0)
  assert_eq(lua_mbt_remove(narrow), 0)
}
