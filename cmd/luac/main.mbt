///|----------------------------------------------------------------
/// `luac`: turn source files into a precompiled chunk.
///
/// The option grammar, the default output name, the way several inputs are
/// combined and the wording of every complaint follow the reference's
/// `luac.c`.  What it *writes* is this build's own chunk encoding: the header is
/// Lua 5.4's, the prototype after it is not, so a chunk produced here loads
/// here and nowhere else, and a `.luac` from the reference is refused (see
/// README, "二进制 chunk 与参考实现不通用").
///
/// Everything below the option table is free of input and output: `build` takes
/// the bytes it is to compile and answers with the bytes and the complaints, so
/// the whole of it -- compiling, combining, listing, dumping -- is reachable from
/// a test without a file system or an exit status.

///|
/// The name complaints are reported under: `argv[0]`, as `luac.c` keeps it.
let progname : Ref[String] = Ref("luac")

///|
/// `OUTPUT`.
let default_output : String = "luac.out"

///|
/// `LUA_COPYRIGHT` has one spelling in the reference and both programs print
/// it; the same is true here, and the banner is the one `lua -v` gives.
let version_text : String = "Lua 5.4  (MoonBit implementation)"

///|
/// What the command line asked for, which is `luac.c`'s four globals plus the
/// place its argument loop stopped.
struct Flags {
  /// How many `-l`: one lists the code, two adds the tables.
  mut listing : Int
  mut dumping : Bool
  mut stripping : Bool
  /// How many `-v`, which is also how the reference notices the whole command
  /// line was nothing but `-v`.
  mut version : Int
  /// Where the input files start in `argv`.
  mut first : Int
  /// Where to write, or `None` for standard output -- what `-o -` asks for.
  mut output : String?
  /// The word that could not be read, empty when all of them could.
  mut bad : String
}

///|
/// `doargs`: an option that takes a value needs one, and that value may not
/// look like another option; anything that does not start with `-` ends the
/// options and is a file name.
fn collect_args(argv : Array[String]) -> Flags {
  let flags : Flags = {
    listing: 0,
    dumping: true,
    stripping: false,
    version: 0,
    first: 1,
    output: Some(default_output),
    bad: "",
  }
  let n = argv.length()
  let mut i = 1
  let mut stop = false
  while i < n && !stop {
    let a = argv[i]
    if a.length() == 0 || a.get_char(0) != Some('-') {
      stop = true
    } else if a == "--" {
      // Everything after `--` is a file name, and a `-v` seen before it still
      // owes a version line after it -- which is what the reference counts it
      // again for here.
      i = i + 1
      if flags.version > 0 {
        flags.version = flags.version + 1
      }
      stop = true
    } else if a == "-" {
      // Standard input is the file, and nothing after it is an option.
      stop = true
    } else if a == "-l" {
      flags.listing = flags.listing + 1
    } else if a == "-p" {
      flags.dumping = false
    } else if a == "-s" {
      flags.stripping = true
    } else if a == "-v" {
      flags.version = flags.version + 1
    } else if a == "-o" {
      i = i + 1
      if i >= n {
        flags.bad = "'-o' needs argument"
        stop = true
      } else {
        let name = argv[i]
        // A bare `-` means standard output; any other word starting with `-` is
        // the next option, which cannot be a file name.
        if name.length() == 0 ||
          (name.get_char(0) == Some('-') && name.length() != 1) {
          flags.bad = "'-o' needs argument"
          stop = true
        } else {
          flags.output = if name == "-" { None } else { Some(name) }
        }
      }
    } else {
      flags.bad = a
      stop = true
    }
    if !stop {
      i = i + 1
    }
  }
  // Asked to list or not to dump, with nothing to read: the reference takes the
  // file it would have written as its input, which is what lets `luac -l` look
  // at the chunk it just produced.
  if i == n && flags.bad == "" && (flags.listing > 0 || !flags.dumping) {
    flags.dumping = false
    i = i - 1
    argv[i] = default_output
  }
  flags.first = i
  flags
}

///|
/// The complaint and the option list, exactly as `usage` writes them: a message
/// that starts with a `-` is an unknown option, anything else is said as it is.
fn usage_text(message : String) -> String {
  let why = if message.length() > 0 && message.get_char(0) == Some('-') {
    "unrecognized option '" + message + "'"
  } else {
    message
  }
  progname.val +
  ": " +
  why +
  "\n" +
  "usage: " +
  progname.val +
  " [options] [filenames]\n" +
  "Available options are:\n" +
  "  -l       list (use -l -l for full listing)\n" +
  "  -o name  output to file 'name' (default is \"" +
  default_output +
  "\")\n" +
  "  -p       parse only\n" +
  "  -s       strip debug information\n" +
  "  -v       show version information\n" +
  "  --       stop handling options\n" +
  "  -        stop handling options and process stdin\n"
}

///|
/// One input, already read.  `name` is what the chunk is called -- the file name
/// with the reference's `@` in front of it, or `=stdin`.
struct Input {
  name : String
  data : Bytes
}

///|
/// What a run decided: the listing it owes, the complaint it has, and the chunk
/// it would write.  `err` is empty when the run did what was asked.
struct Outcome {
  listing : Bytes
  err : String
  chunk : Bytes
}

///|
/// The closure a compiled chunk always is: its prototype.
fn proto_of(v : @core.Value) -> @core.LProto? {
  match v {
    @core.VFunc(cl) => Some(cl.proto)
    _ => None
  }
}

///|
/// Compiles text that is already in hand.  A load failure carries the file and
/// the line in its own message, which is what `lua_tostring(L,-1)` answers with
/// after `luaL_loadfile` fails.
fn compile_text(
  st : @core.LuaState,
  data : Bytes,
  name : String,
) -> (@core.LProto?, String) {
  match
    @load.compile_source(
      st,
      @load.strip_chunk_prefix(data),
      name,
      @core.VTable(st.globals),
    ) {
    @core.LoadOk(v) =>
      match proto_of(v) {
        Some(p) => (Some(p), "")
        None => (None, "cannot compile " + name)
      }
    @core.LoadError(msg) => (None, @core.text_of(msg))
  }
}

///|
/// The chunk written when several files were named: a closure per input, called
/// in the order they were given, each discarding what it returns.
///
/// `luac.c` builds this by compiling `(function()end)();` once per input and
/// dropping each file's prototype into the empty function it calls.  The same
/// splice needs the instructions that follow a `CLOSURE` -- the ones that say
/// where each upvalue comes from -- to be there for the *spliced* prototype's
/// upvalues, and the stub's own functions have none.  So the wrapper is
/// assembled here instead, from the same shapes the compiler emits, which keeps
/// the description of every upvalue next to the closure that reads it.
fn wrapper(protos : Array[@core.LProto]) -> @core.LProto {
  let code : Array[@core.Instr] = []
  let lines : Array[Int] = []
  let mut i = 0
  while i < protos.length() {
    code.push(@core.instr(@core.OP_CLOSURE, 0, i, 0))
    lines.push(1)
    // One per upvalue, naming the slot it comes from: a register of this frame
    // or one of its own upvalues, as `compiler_entry` emits them.
    for d in protos[i].upvals {
      let pseudo = if d.in_stack { @core.OP_MOVE } else { @core.OP_GETUPVAL }
      code.push(@core.instr(pseudo, 0, d.index, 0))
      lines.push(1)
    }
    // Called with no arguments: what a file's chunk sees as `...` is nothing,
    // which is what `luac.c`'s stub does too.
    code.push(@core.instr(@core.OP_CALL, 0, 1, 1))
    lines.push(1)
    i = i + 1
  }
  code.push(@core.instr(@core.OP_RETURN, 0, 1, 0))
  lines.push(1)
  {
    code,
    lines,
    constants: [],
    protos,
    // The same single upvalue a main chunk is given, which is what the inputs
    // above read their globals from.  `attrib` is `ATTRIB_NONE`.
    upvals: [
      {
        name: @core.LStr::of_string("_ENV"),
        in_stack: false,
        index: 0,
        attrib: 0,
      },
    ],
    numparams: 0,
    is_vararg: false,
    maxstack: 2,
    source: @core.LStr::of_string("=(luac)"),
    line_defined: 0,
    last_line_defined: 0,
    locvars: [],
    name: "",
  }
}

///|
/// `combine`: one input is written as itself; several go inside the wrapper.
fn combine(protos : Array[@core.LProto]) -> @core.LProto {
  if protos.length() == 1 {
    protos[0]
  } else {
    wrapper(protos)
  }
}

///|
/// Everything a run decides, with no input and no output: read the inputs,
/// compile them, combine them, list the result, dump it.
fn build(st : @core.LuaState, inputs : Array[Input], flags : Flags) -> Outcome {
  let protos : Array[@core.LProto] = []
  for one in inputs {
    let (p, why) = compile_text(st, one.data, one.name)
    match p {
      None =>
        // A failure stops the run before the listing or the dump, as `fatal`
        // does there.
        return { listing: Bytes::new(0), err: why, chunk: Bytes::new(0), }
      Some(proto) => protos.push(proto)
    }
  }
  let proto = combine(protos)
  {
    listing: if flags.listing > 0 {
      listing_bytes(proto, flags.listing > 1)
    } else {
      Bytes::new(0)
    },
    err: "",
    chunk: if flags.dumping {
      @chunk.dump_proto(proto, flags.stripping)
    } else {
      Bytes::new(0)
    },
  }
}

///|
/// The exit status of a run that got as far as deciding something.
fn run_command(flags : Flags, outcome : Outcome) -> Int {
  if outcome.err != "" {
    @core.write_stderr(@core.bytes_of(progname.val + ": " + outcome.err + "\n"))
    return 1
  }
  if outcome.listing.length() > 0 {
    @core.write_stdout(outcome.listing)
    @core.flush_stdout()
  }
  if flags.dumping {
    match flags.output {
      // Two things are true of standard output here, and the reference shares
      // the second one because it too opens only the *file* with "wb": the
      // host write reports nothing, so a short write is silent; and on Windows
      // stdout is a text stream, which turns every `0x0A` of the chunk into
      // `0D 0A` -- measured on a 222-byte chunk that arrives 225 bytes long
      // and is then refused as a corrupted chunk.  Write a file to get the
      // bytes back.
      None => {
        @core.write_stdout(outcome.chunk)
        @core.flush_stdout()
      }
      Some(path) =>
        match @core.write_file_staged(@core.bytes_of(path), outcome.chunk) {
          Ok(_) => ()
          Err((stage, why)) => {
            let complaint = progname.val +
              ": cannot " +
              stage +
              " " +
              path +
              ": " +
              @core.text_of(why)
            @core.write_stderr(@core.bytes_of(complaint + "\n"))
            return 1
          }
        }
    }
  }
  0
}

///|
fn main {
  let argv = @env.args()
  if argv.length() > 0 {
    progname.val = argv[0]
  }
  let flags = collect_args(argv)
  if flags.bad != "" {
    @core.write_stderr(@core.bytes_of(usage_text(flags.bad)))
    @core.host_exit(1)
  }
  if flags.version > 0 {
    @core.write_stdout(@core.bytes_of(version_text + "\n"))
    @core.flush_stdout()
    // `-v` as the whole command line is an answer, not a request to compile.
    if flags.version == argv.length() - 1 {
      @core.host_exit(0)
    }
  }
  let files = argv[flags.first:]
  if files.length() == 0 {
    @core.write_stderr(@core.bytes_of(usage_text("no input files given")))
    @core.host_exit(1)
  }
  // The reference opens a bare state.  Libraries do not change what a chunk
  // compiles to, and the state's global table is what the chunk reads `_ENV`.
  let state = @lua.create()
  let inputs : Array[Input] = []
  for path in files {
    if path == "-" {
      inputs.push({ name: "=stdin", data: @core.read_stdin_all(), })
    } else {
      match @core.read_whole_file(@core.bytes_of(path)) {
        Err(e) => {
          // `luaL_loadfile` says it this way, and `luac.c` prints that string.
          @core.write_stderr(
            @core.bytes_of(
              progname.val +
              ": cannot open " +
              path +
              ": " +
              @core.text_of(e) +
              "\n",
            ),
          )
          @core.host_exit(1)
        }
        Ok(data) => inputs.push({ name: "@" + path, data, })
      }
    }
  }
  let status = run_command(flags, build(state, inputs, flags))
  if status != 0 {
    @core.host_exit(status)
  }
}
