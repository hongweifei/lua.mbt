// White-box tests for the package library.  The entry a shared library is asked
// for never appears in a Lua-visible message -- the reference names the *module*
// in `no module 'a.b' in file ...` and the *loader's* reason everywhere else --
// so the naming rule it works out can only be checked from inside the package.

///|
test "the entry names loadfunc asks for" {
  // A module's dots become underscores: `a.b` lives in `luaopen_a_b`.
  assert_eq(openfunc_names("a.b"), ["luaopen_a_b"])
  assert_eq(openfunc_names("conf"), ["luaopen_conf"])
  assert_eq(openfunc_names("a.b.c"), ["luaopen_a_b_c"])
  // The ignore mark (`-`, the fifth line of `package.config`) cuts the name in
  // two, and both halves are tried -- the front one first.
  assert_eq(openfunc_names("a-b"), ["luaopen_a", "luaopen_b"])
  // The fallback is the rest of the name *as it stands*: only the dots turned
  // into underscores are gone, and a second mark stays where it was.
  assert_eq(openfunc_names("a-b-c"), ["luaopen_a", "luaopen_b-c"])
  assert_eq(openfunc_names("a.b-c"), ["luaopen_a_b", "luaopen_c"])
  // Nothing here refuses an odd spelling; the reference's `loadfunc` simply asks
  // for what the name spells, and a name with no C function behind it is the
  // library's answer, not this one's.
  assert_eq(openfunc_names("-x"), ["luaopen_", "luaopen_x"])
}
