// The shell is checked on its own: the option table before any state exists,
// then the whole pipeline -- compile, combine, list, dump -- by running the
// bytes it produces back through the interpreter.

///|
fn flags_of(args : Array[String]) -> Flags {
  collect_args(["luac"] + args)
}

///|
fn input_of(name : String, source : String) -> Input {
  { name, data: @core.bytes_of(source), }
}

///|
/// Compiles one input and fails the test if it would not compile, so the
/// listing tests can talk about a prototype alone.
fn compile_only(st : @core.LuaState, one : Input) -> @core.LProto raise {
  match compile_text(st, one.data, one.name) {
    (Some(p), _) => p
    (None, why) => fail("the test's own chunk did not compile: " + why)
  }
}

///|
/// Runs a chunk and reports its failure text, so a broken round trip says what
/// went wrong instead of only that it did.
fn run_chunk(
  state : @core.LuaState,
  chunk : Bytes,
  name : String,
) -> Unit raise {
  let (ok, values) = @lua.run_bytes(state, chunk, name)
  if !ok {
    let why = if values.length() > 0 {
      @core.text_of(@lua.error_text(state, values[0]))
    } else {
      "no message"
    }
    fail("the chunk did not run: " + why)
  }
}

///|
test "the options are collected like the reference" {
  let plain = flags_of(["a.lua"])
  debug_inspect(
    (plain.listing, plain.dumping, plain.stripping, plain.version, plain.first),
    content="(0, true, false, 0, 1)",
  )
  let all = flags_of(["-l", "-l", "-s", "-p", "a.lua"])
  debug_inspect(
    (all.listing, all.stripping, all.dumping, all.first),
    content="(2, true, false, 5)",
  )
  // `-o` names the file; a bare `-` there means standard output.
  debug_inspect(
    flags_of(["-o", "out.luac", "a.lua"]).output,
    content="Some(\"out.luac\")",
  )
  debug_inspect(flags_of(["-o", "-", "a.lua"]).output, content="None")
  // The first non-option ends them, and `--` ends them by saying so.
  debug_inspect(flags_of(["--", "-o"]).first, content="2")
  debug_inspect(flags_of(["-"]).first, content="1")
}

///|
test "an option that needs an argument is refused" {
  // No argument at all, and one that is itself an option.
  debug_inspect(
    flags_of(["-o"]).bad,
    content=(
      #|"'-o' needs argument"
    ),
  )
  debug_inspect(
    flags_of(["-o", "-l", "a.lua"]).bad,
    content=(
      #|"'-o' needs argument"
    ),
  )
  // An empty word is not an answer either.
  debug_inspect(
    flags_of(["-o", ""]).bad,
    content=(
      #|"'-o' needs argument"
    ),
  )
  debug_inspect(
    flags_of(["-x", "a.lua"]).bad,
    content=(
      #|"-x"
    ),
  )
  debug_inspect(
    flags_of(["-l", "a.lua"]).bad,
    content=(
      #|""
    ),
  )
}

///|
test "usage names the complaint before listing the options" {
  // The option list is the reference's, in its order, with its default name.
  debug_inspect(
    usage_text("-x"),
    content=(
      #|"luac: unrecognized option '-x'\nusage: luac [options] [filenames]\nAvailable options are:\n  -l       list (use -l -l for full listing)\n  -o name  output to file 'name' (default is \"luac.out\")\n  -p       parse only\n  -s       strip debug information\n  -v       show version information\n  --       stop handling options\n  -        stop handling options and process stdin\n"
    ),
  )
  // A message that is not an option is said as it is.
  let no_input = usage_text("no input files given")
  assert_true(no_input.has_prefix("luac: no input files given\n"))
  assert_true(
    usage_text("'-o' needs argument").has_prefix("luac: '-o' needs argument\n"),
  )
}

///|
/// Asked to list, or not to dump, with no file named, the reference reads the
/// file it would have written: that is what lets `luac -l` look at the chunk it
/// just produced.  `collect_args` mutates the words it was given, as `doargs`
/// does to `argv`.
test "listing with no input names the default output instead" {
  let argv = ["luac", "-l"]
  let flags = collect_args(argv)
  debug_inspect((flags.dumping, flags.first), content="(false, 1)")
  debug_inspect(
    argv[flags.first],
    content=(
      #|"luac.out"
    ),
  )
  // A named input is left alone, so `-p a.lua` does not read the output file.
  let with_file = ["luac", "-p", "a.lua"]
  let parsed = collect_args(with_file)
  debug_inspect((parsed.dumping, parsed.first), content="(false, 2)")
}

///|
test "a chunk compiled here runs here" {
  let state = @lua.create()
  // The assertions are inside the chunk, so a round trip that lost a value or
  // an upvalue fails rather than merely printing something different.
  let source = "local x = 41\nlocal function f() return x + 1 end\nassert(f() == 42)\n"
  let outcome = build(state, [input_of("@a.lua", source)], flags_of(["a.lua"]))
  debug_inspect(
    outcome.err,
    content=(
      #|""
    ),
  )
  run_chunk(state, outcome.chunk, "@a.lua")
}

///|
test "several inputs run in the order they were named" {
  let state = @lua.create()
  let inputs = [
    input_of("@a.lua", "_G.order = 'A'"),
    // Each one checks what its predecessors left, so an input dropped or moved
    // makes the run fail instead of looking like it worked.
    input_of(
      "@b.lua", "assert(_G.order == 'A', 'b ran first')\n_G.order = 'AB'",
    ),
    input_of(
      "@c.lua", "assert(_G.order == 'AB', 'c ran before b')\n_G.order = 'ABC'",
    ),
  ]
  let outcome = build(state, inputs, flags_of(["a.lua", "b.lua", "c.lua"]))
  run_chunk(state, outcome.chunk, "@abc.lua")
  // The wrapper holds them: one closure, one upvalue descriptor and one call
  // per input, then the implicit return.
  let listing = @core.text_of(
    listing_bytes(wrapper(inputs.map(p => compile_only(state, p))), false),
  )
  assert_true(listing.contains("main <(luac):0,0> (10 instructions)"))
  assert_true(listing.has_prefix("\nmain <(luac):0,0>"))
}

///|
test "strip writes a smaller chunk that still runs" {
  let state = @lua.create()
  let source = "local x = 1\nassert(x == 1)\nreturn x"
  let inputs = [input_of("@a.lua", source)]
  let plain = build(state, inputs, flags_of(["a.lua"]))
  let stripped = build(state, inputs, flags_of(["-s", "a.lua"]))
  assert_true(stripped.chunk.length() < plain.chunk.length())
  run_chunk(state, stripped.chunk, "@a.lua")
}

///|
/// `-p` says the chunk compiles and writes nothing.
test "parse only lists and writes nothing" {
  let state = @lua.create()
  let outcome = build(
    state,
    [input_of("@a.lua", "return 1")],
    flags_of(["-l", "-p", "a.lua"]),
  )
  assert_eq(outcome.chunk.length(), 0)
  assert_true(outcome.listing.length() > 0)
  // Without `-l`, `-p` produces neither bytes nor text.
  let quiet = build(state, [input_of("@a.lua", "return 1")], flags_of(["-p"]))
  debug_inspect(
    (quiet.chunk.length(), quiet.listing.length()),
    content="(0, 0)",
  )
}

///|
test "the listing of a small chunk" {
  let state = @lua.create()
  let proto = compile_only(
    state,
    input_of(
      "@p.lua", "local n = 2\nlocal function twice(x) return x * n end\nreturn twice(3)",
    ),
  )
  debug_inspect(
    @core.text_of(listing_bytes(proto, false)),
    content=(
      #|"\nmain <p.lua:0,0> (9 instructions)\n0+ params, 12 slots, 1 upvalue, 2 locals, 2 constants, 1 function\n\t1\t[1]\tLOADK    \t0 0\t; k0 2\n\t2\t[2]\tCLOSURE  \t1 0\t;  function <p.lua:2,2>\n\t3\t[2]\tMOVE     \t0 0\n\t4\t[3]\tMOVE     \t2 1\n\t5\t[3]\tLOADK    \t3 1\t; k1 3\n\t6\t[3]\tTAILCALL \t2 2 0\t; 1 in\n\t7\t[3]\tRETURN   \t2 0\t; all out\n\t8\t[3]\tRETURN   \t2 1\t; 0 out\n\t9\t[3]\tCLOSE    \t0\n\nfunction <p.lua:2,2> (5 instructions)\n1 param, 11 slots, 1 upvalue, 1 local, 0 constants, 0 functions\n\t1\t[2]\tMOVE     \t1 0\n\t2\t[2]\tGETUPVAL \t2 0\t; n\n\t3\t[2]\tMUL      \t1 1 2\n\t4\t[2]\tRETURN   \t1 2\t; 1 out\n\t5\t[2]\tRETURN   \t1 1\t; 0 out\n"
    ),
  )
}

///|
/// A full listing adds the three tables, and a string constant is escaped the
/// way the reference prints one: `\t` for a tab, `\%03d` for a byte a terminal
/// would not take.
test "a full listing adds the tables" {
  let state = @lua.create()
  let proto = compile_only(
    state,
    input_of("@t.lua", "local s = 'a\tb\\1' .. string.char(1)\nreturn #s"),
  )
  let full = @core.text_of(listing_bytes(proto, true))
  assert_true(full.contains("constants (4):"))
  assert_true(full.contains("locals (1):"))
  assert_true(full.contains("upvalues (1):"))
  assert_true(full.contains("	S	\"a\\tb\\001\""))
  // The one upvalue of a main chunk is the globals table, read from the frame
  // around it rather than from a register of its own.
  assert_true(full.contains("0	_ENV	0	0"))
}

///|
test "a chunk with no source reports it as the loader does" {
  let state = @lua.create()
  let stripped = build(
    state,
    [input_of("@s.lua", "local x = 1\nreturn x")],
    flags_of(["-s", "s.lua"]),
  )
  // Loading the stripped chunk back gives a prototype with no name for its
  // source, which the listing reads as `?` -- the same thing an error message
  // calls it.
  let reloaded = match
    @load.compile_source(
      state,
      stripped.chunk,
      "@s.luac",
      @core.VTable(state.globals),
    ) {
    @core.LoadOk(@core.VFunc(cl)) => cl.proto
    _ => fail("the stripped chunk should load")
  }
  let header = @core.text_of(listing_bytes(reloaded, false))
  assert_true(header.has_prefix("\nmain <?:0,0>"))
}

///|
/// A compile failure is the chunk's own message, prefix and all, which is what
/// `luac.c` prints after `luaL_loadfile` fails.
test "a file that does not compile is reported with its position" {
  let state = @lua.create()
  let outcome = build(
    state,
    [input_of("@bad.lua", "local =")],
    flags_of(["bad.lua"]),
  )
  debug_inspect(
    (outcome.err, outcome.chunk.length(), outcome.listing.length()),
    content=(
      #|("bad.lua:1: <name> expected near '='", 0, 0)
    ),
  )
}
