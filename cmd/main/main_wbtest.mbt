// The command line is read before any state exists, so its pieces are checked
// on their own: what a set of options says, and how an `-l` argument is split.

///|
test "options are collected like the reference" {
  let o = collect_args(["lua", "-E", "-i", "-W", "-e", "print(1)", "s.lua", "a"])
  assert_eq(o.bad, -1)
  assert_true(o.ignore_env)
  assert_true(o.interactive)
  // `-i` implies `-v`, as it does in the reference.
  assert_true(o.show_version)
  assert_true(o.has_code)
  assert_eq(o.script, 6)
}

///|
test "an option that needs an argument is refused without one" {
  assert_eq(collect_args(["lua", "-e"]).bad, 1)
  // The next word may not itself look like an option.
  assert_eq(collect_args(["lua", "-e", "-x"]).bad, 1)
  assert_eq(collect_args(["lua", "-l", "-"]).bad, 1)
  // The argument may be joined to the option instead.
  assert_eq(collect_args(["lua", "-e", "print(1)"]).bad, -1)
  assert_eq(collect_args(["lua", "-eprint(1)"]).bad, -1)
}

///|
test "an unknown option is refused" {
  assert_eq(collect_args(["lua", "-x"]).bad, 1)
  assert_eq(collect_args(["lua", "--x"]).bad, 1)
  assert_eq(collect_args(["lua", "-ix"]).bad, 1)
}

///|
test "a script name ends the options" {
  let o = collect_args(["lua", "s.lua", "-e", "x"])
  assert_eq(o.script, 1)
  assert_true(!o.has_code)
  // `--` may introduce the script name.
  assert_eq(collect_args(["lua", "--", "-e"]).script, 2)
  // `-` is the script that reads standard input.
  assert_eq(collect_args(["lua", "-"]).script, 1)
  // With no script name every index is its own position.
  assert_eq(collect_args(["lua", "-v"]).script, 0)
}

///|
test "an -l argument names the global and the module" {
  let (g1, m1) = library_names("mymod")
  assert_eq(g1, "mymod")
  assert_eq(m1, "mymod")
  // A `-suffix` is the version: the global keeps the bare name.
  let (g2, m2) = library_names("mymod-v1")
  assert_eq(g2, "mymod")
  assert_eq(m2, "mymod-v1")
  // An explicit name wins over the suffix rule.
  let (g3, m3) = library_names("g=mymod-v1")
  assert_eq(g3, "g")
  assert_eq(m3, "mymod-v1")
  let (g4, m4) = library_names("g=")
  assert_eq(g4, "g")
  assert_eq(m4, "")
}

///|
test "the words after a script name are its varargs" {
  let state = @lua.create_ignoring_env(true)
  let src =
    #|local n = select('#', ...)
    #|assert(n == 2, 'n = ' .. n)
    #|assert((...) == 'a')
    #|assert(select(2, ...) == 'b')
  assert_true(run_chunk(state, @core.bytes_of(src), "=test", ["a", "b"]))
  // With no words after the name there are no varargs to read.
  assert_true(
    run_chunk(state, @core.bytes_of("assert(select('#', ...) == 0)"), "=test", []),
  )
}

///|
test "a chunk from a file drops a byte order mark and a # line" {
  let state = @lua.create_ignoring_env(true)
  assert_true(run_chunk(state, b"\xEF\xBB\xBFassert(true)", "=test", []))
  // The dropped line leaves its newline behind, so `return` is still on the
  // second line of the file -- the official suite checks exactly this.
  assert_true(
    run_chunk(
      state,
      b"#!/usr/bin/lua\nassert(debug.getinfo(1).currentline == 2)",
      "=test",
      [],
    ),
  )
}
