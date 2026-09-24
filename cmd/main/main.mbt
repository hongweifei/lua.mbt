///|----------------------------------------------------------------
/// The command line interface.
///
/// Usage follows the reference interpreter:
///   lua [options] [script [args]]
/// where the options are `-e stat`, `-l mod`, `-i`, `-v`, `-E`, `-W` and `--`.
/// The global table `arg` is built the same way, so a script can inspect the
/// command line it was given, and the environment is read the same way: a
/// `LUA_INIT` preamble runs first and the package library takes `LUA_PATH` and
/// `LUA_CPATH` into account unless `-E` was given.

///|----------------------------------------------------------------

///|
/// The name the interpreter reports errors under, which is `argv[0]` as the
/// reference's `l_message` uses.
let progname : Ref[String] = Ref("lua")

///|
/// The version banner.
let version_text : String = "Lua 5.4  (MoonBit implementation)"

///|
fn print_version() -> Unit {
  @core.write_stdout(@core.bytes_of(version_text + "\n"))
  @core.flush_stdout()
}

///|
/// What the arguments ask for, the reference's `collectargs`: which options are
/// present, where the script name is, and which argument could not be
/// understood.
struct Options {
  mut interactive : Bool
  mut show_version : Bool
  /// Whether an `-e` or `-l` option is present.  The reference reuses its
  /// "has -e" bit for both, and so does the test for an active option.
  mut has_code : Bool
  mut ignore_env : Bool
  /// The index of the script name in `argv`, or 0 when there is none.
  mut script : Int
  /// The index of the option that could not be understood, or -1.
  mut bad : Int
}

///|
/// Reads the options up to the script name, exactly as `collectargs` does: an
/// option that takes an argument needs one, and the argument may not itself
/// look like an option.
fn collect_args(argv : Array[String]) -> Options {
  let opts : Options = {
    interactive: false,
    show_version: false,
    has_code: false,
    ignore_env: false,
    script: 0,
    bad: -1,
  }
  let mut i = 1
  while i < argv.length() {
    let a = argv[i]
    if a.length() == 0 || a.get_char(0) != Some('-') {
      opts.script = i
      return opts
    }
    match a.get_char(1) {
      // "-" is the script name meaning "read stdin".
      None => {
        opts.script = i
        return opts
      }
      // "--" ends the options; a script name may follow it.
      Some('-') => {
        if a.length() != 2 {
          opts.bad = i
          return opts
        }
        opts.script = if i + 1 < argv.length() { i + 1 } else { 0 }
        return opts
      }
      Some('E') => {
        if a.length() != 2 {
          opts.bad = i
          return opts
        }
        opts.ignore_env = true
      }
      Some('W') =>
        if a.length() != 2 {
          opts.bad = i
          return opts
        }
      // `-i` implies `-v`, which is why it falls through in the reference.
      Some('i') => {
        opts.interactive = true
        if a.length() != 2 {
          opts.bad = i
          return opts
        }
        opts.show_version = true
      }
      Some('v') => {
        if a.length() != 2 {
          opts.bad = i
          return opts
        }
        opts.show_version = true
      }
      Some('e') | Some('l') => {
        opts.has_code = true
        if a.length() == 2 {
          // The argument is the next word, which must exist and must not be
          // another option; the option itself is what the usage names.
          i = i + 1
          if i >= argv.length() ||
            (argv[i].length() > 0 && argv[i].get_char(0) == Some('-')) {
            opts.bad = i - 1
            return opts
          }
        }
      }
      _ => {
        opts.bad = i
        return opts
      }
    }
    i = i + 1
  }
  opts.script = 0
  opts
}

///|
/// The reference's `print_usage`: the offending option first, then the list.
fn print_usage(badoption : String) -> Unit {
  let why = match badoption.get_char(1) {
    Some('e') | Some('l') => "'" + badoption + "' needs argument"
    _ => "unrecognized option '" + badoption + "'"
  }
  @core.write_stderr(
    @core.bytes_of(
      progname.val +
      ": " +
      why +
      "\n" +
      "usage: " +
      progname.val +
      " [options] [script [args]]\n" +
      "Available options are:\n" +
      "  -e stat   execute string 'stat'\n" +
      "  -i        enter interactive mode after executing 'script'\n" +
      "  -l mod    require library 'mod' into global 'mod'\n" +
      "  -l g=mod  require library 'mod' into global 'g'\n" +
      "  -v        show version information\n" +
      "  -E        ignore environment variables\n" +
      "  -W        turn warnings on\n" +
      "  --        stop handling options\n" +
      "  -         stop handling options and execute stdin\n",
    ),
  )
}

///|
/// Builds the `arg` table: `arg[0]` is the script, negative indices the
/// interpreter and its options.  With no script name every index is its own
/// position, so `arg[0]` is the program name, exactly as `createargtable`
/// leaves it.
fn build_arg_table(
  state : @core.LuaState,
  argv : Array[String],
  script_index : Int,
) -> Unit {
  let t = @core.LTable::new()
  let mut i = 0
  while i < argv.length() {
    t.set_int((i - script_index).to_int64(), @lua.value_string(argv[i]))
    i = i + 1
  }
  @lua.set_global_arg(state, t)
}

///|
fn report_message(msg : Bytes) -> Unit {
  @core.write_stderr(
    @core.bytes_concat([
      @core.bytes_of(progname.val + ": "),
      msg,
      @core.bytes_of("\n"),
    ]),
  )
}

///|
/// Splits an `-l` argument into the global to store the module in and the
/// module to require, the reference's `dolibrary`.  Without an explicit
/// `=modulename` the two are the same, except that a `-suffix` is cut off the
/// global: that is how a versioned library file installs itself under the bare
/// name.
fn library_names(spec : String) -> (String, String) {
  match spec.find("=") {
    Some(i) => (spec[:i].to_owned(), spec[i + 1:].to_owned())
    None =>
      match spec.find("-") {
        Some(i) => (spec[:i].to_owned(), spec)
        None => (spec, spec)
      }
  }
}

///|
/// Loads a module and stores it in a global, like `-l`.
fn require_module(state : @core.LuaState, spec : String) -> Bool {
  let (glob, modname) = library_names(spec)
  let req = @lua.global_field(state, "require")
  let (vals, msg) = @lua.call_with_handler(state, req, [
    @lua.value_string(modname),
  ])
  match vals {
    Some(vs) => {
      let v = if vs.length() > 0 { vs[0] } else { @lua.value_nil() }
      @lua.set_global(state, glob, v)
      true
    }
    None => {
      report_message(msg)
      false
    }
  }
}

///|
/// Loads and runs a file, passing the script arguments through `arg`.
fn run_script(state : @core.LuaState, path : String) -> Bool {
  let raw = if path == "-" {
    @load.read_stdin_all()
  } else {
    match @core.read_whole_file(@core.bytes_of(path)) {
      Ok(d) => d
      Err(e) => {
        @core.write_stderr(
          @core.bytes_concat([
            @core.bytes_of(progname.val + ": cannot open "),
            @core.bytes_of(path),
            @core.bytes_of(": "),
            e,
            @core.bytes_of("\n"),
          ]),
        )
        return false
      }
    }
  }
  // A chunk loaded from a file may start with a `#!` shebang line; strip it,
  // like luaL_loadfilex does in the reference implementation (a `#` first
  // line stays an error for chunks loaded from strings).
  let data = if raw.length() > 0 && raw.at(0) == 35 {
    let mut i = 0
    while i < raw.length() {
      let b = raw.at(i)
      i = i + 1
      if b == 10 {
        break
      }
      if b == 13 {
        if i < raw.length() && raw.at(i) == 10 {
          i = i + 1
        }
        break
      }
    }
    @core.bytes_slice(raw, i, raw.length() - i)
  } else {
    raw
  }
  let name = if path == "-" { "=stdin" } else { "@" + path }
  let (status, msg) = @lua.run_protected_reporting(state, data, name)
  if status != 0 {
    report_message(msg)
  }
  status == 0
}

///|
/// Runs the `LUA_INIT_5_4` or `LUA_INIT` preamble, unless `-E` was given.  A
/// value starting with `@` names a file to run; anything else is the code.  It
/// runs before the `-e`/`-l` options and the script, so a program can be given a
/// preamble from the environment.
fn run_init(state : @core.LuaState) -> Bool {
  let chunk = fn(v : Bytes, name : String) -> Bool {
    if v.length() > 0 && v.at(0) == 64 {
      run_script(state, @core.text_of(@core.bytes_slice(v, 1, v.length() - 1)))
    } else {
      let (status, msg) = @lua.run_protected_reporting(state, v, name)
      if status != 0 {
        report_message(msg)
      }
      status == 0
    }
  }
  match @oslib.os_env("LUA_INIT_5_4") {
    Some(v) => chunk(v, "=LUA_INIT_5_4")
    None =>
      match @oslib.os_env("LUA_INIT") {
        Some(v) => chunk(v, "=LUA_INIT")
        None => true
      }
  }
}

///|
/// Processes the `-e`, `-l` and `-W` options in the order they were written,
/// which is what `runargs` does.  Returns false as soon as one of them fails.
fn run_options(
  state : @core.LuaState,
  argv : Array[String],
  limit : Int,
) -> Bool {
  let mut i = 1
  while i < limit {
    let a = argv[i]
    let option = a.get_char(1)
    if option == Some('W') {
      @lua.set_warnings_enabled(state, true)
    } else if option == Some('e') || option == Some('l') {
      let code = if a.length() > 2 {
        a[2:].to_owned()
      } else {
        i = i + 1
        argv[i]
      }
      let ok = if option == Some('e') {
        let (status, msg) = @lua.run_protected_reporting(
          state,
          @core.bytes_of(code),
          "=(command line)",
        )
        if status != 0 {
          report_message(msg)
        }
        status == 0
      } else {
        require_module(state, code)
      }
      if !ok {
        return false
      }
    }
    i = i + 1
  }
  true
}

///|
/// The prompt to show before reading a line: the `_PROMPT` global for a fresh
/// line and `_PROMPT2` for a continuation, or the built-in pair.
fn prompt_for(state : @core.LuaState, first : Bool) -> Bytes {
  let name = if first { "_PROMPT" } else { "_PROMPT2" }
  let v = @lua.global_field(state, name)
  if v.is_nil() {
    @core.bytes_of(if first { "> " } else { ">> " })
  } else {
    @lua.error_text(state, v)
  }
}

///|
/// The interactive read-eval-print loop.  A chunk that fails to compile because
/// the input ends in the middle of a construct is continued on the next line.
///
/// Errors are reported without the program name and with a traceback, which is
/// what the reference's `doREPL` asks for by clearing `progname` around the
/// loop.
fn repl(state : @core.LuaState) -> Unit {
  let mut pending = Buffer::Buffer(size_hint=256)
  let mut incomplete = false
  let stdin = @lua.stdin_stream()
  while true {
    if !incomplete {
      pending = Buffer::Buffer(size_hint=256)
    }
    @core.write_stdout(prompt_for(state, !incomplete))
    @core.flush_stdout()
    let line = @iolib.read_line_from(stdin, true)
    match line {
      @core.VNil => break
      @core.VStr(s) => pending.write_bytes(s.data().view())
      _ => break
    }
    let text = pending.to_bytes()
    // Try the input as an expression first, so that a bare expression prints its
    // value, then as a statement.
    let as_expr = @lua.try_load(
      state,
      @core.bytes_concat([@core.bytes_of("return "), text]),
      "=stdin",
    )
    let loaded = match as_expr {
      Some(f) => Some(f)
      None => @lua.try_load(state, text, "=stdin")
    }
    match loaded {
      Some(f) => {
        incomplete = false
        match @lua.call_printed(state, f) {
          Some(msg) =>
            @core.write_stderr(@core.bytes_concat([msg, @core.bytes_of("\n")]))
          None => ()
        }
      }
      None => {
        let msg = match @lua.last_load_error(state) {
          Some(m) => m
          None => @core.bytes_of("")
        }
        // An error that mentions the end of the input usually means the user is
        // * still typing.
        if @lua.bytes_ends_with(msg, @core.bytes_of("<eof>'")) {
          incomplete = true
        } else {
          incomplete = false
          @core.write_stderr(@core.bytes_concat([msg, @core.bytes_of("\n")]))
        }
      }
    }
  }
  @core.write_stdout(@core.bytes_of("\n"))
  @core.flush_stdout()
}

///|
/// Entry point.
fn main {
  let args : Array[String] = @env.args()
  if args.length() > 0 {
    progname.val = args[0]
  }
  let opts = collect_args(args)
  if opts.bad >= 0 {
    print_usage(args[opts.bad])
    @core.host_exit(1)
  }
  if opts.show_version {
    print_version()
  }
  // `-E` has to be known before the libraries are opened, because it is the
  // package library that reads the environment.
  let state = @lua.create_ignoring_env(opts.ignore_env)
  build_arg_table(state, args, opts.script)
  let mut ok = true
  if !opts.ignore_env {
    ok = run_init(state)
  }
  if ok {
    let limit = if opts.script > 0 { opts.script } else { args.length() }
    ok = run_options(state, args, limit)
  }
  if ok && opts.script > 0 {
    ok = run_script(state, args[opts.script])
  }
  if !ok {
    @core.host_exit(1)
  }
  if opts.interactive {
    repl(state)
  } else if opts.script < 1 && !opts.has_code && !opts.show_version {
    if @lua.stdin_is_tty() {
      print_version()
      repl(state)
    } else {
      let data = @load.read_stdin_all()
      let (status, msg) = @lua.run_protected_reporting(state, data, "=stdin")
      if status != 0 {
        report_message(msg)
        @core.host_exit(1)
      }
    }
  }
}
