// The package library.

///|
/// The directory separator of the host, the reference's `LUA_DIRSEP`: `\` on
/// Windows and `/` elsewhere.  It is the first line of `package.config`, and it
/// is what a module name's dots are turned into when a searcher looks for a
/// file.
pub fn dirsep() -> String {
  if @host.lua_mbt_is_windows() != 0 {
    "\\"
  } else {
    "/"
  }
}

///|
/// The directory holding the running executable, without a trailing separator,
/// or the empty string when the host cannot name it.
fn exec_dir() -> String {
  let mut size = 1024
  while size < 1048576 {
    let buf = Bytes::new(size)
    let n = @host.lua_mbt_exec_dir(buf, size)
    if n < 0 {
      return ""
    }
    if n < size {
      return @core.text_of(@core.bytes_slice(buf, 0, n))
    }
    size = n + 1
  }
  ""
}

///|
/// The default `package.path`, the reference's `LUA_PATH_DEFAULT` for the host.
/// On Windows the directories beside the executable come first, written with
/// `!` standing for it; elsewhere the installation tree under `/usr/local`
/// does.  Either way the working directory comes last.
fn default_path() -> String {
  if @host.lua_mbt_is_windows() != 0 {
    "!\\lua\\?.lua;!\\lua\\?\\init.lua;!\\?.lua;!\\?\\init.lua;" +
    "!\\..\\share\\lua\\5.4\\?.lua;!\\..\\share\\lua\\5.4\\?\\init.lua;" +
    ".\\?.lua;.\\?\\init.lua"
  } else {
    "/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua;" +
    "/usr/local/lib/lua/5.4/?.lua;/usr/local/lib/lua/5.4/?/init.lua;" +
    "./?.lua;./?/init.lua"
  }
}

///|
/// The default `package.cpath`, the reference's `LUA_CPATH_DEFAULT` for the
/// host.  A file found there is opened for real -- the loader's own reason is
/// what `require` reports -- but this build cannot enter what it finds, so these
/// templates name nothing that can be loaded.
fn default_cpath() -> String {
  if @host.lua_mbt_is_windows() != 0 {
    "!\\?.dll;!\\..\\lib\\lua\\5.4\\?.dll;!\\loadall.dll;.\\?.dll"
  } else {
    "/usr/local/lib/lua/5.4/?.so;/usr/local/lib/lua/5.4/loadall.so;./?.so"
  }
}

///|
/// The marking characters of the path templates, in the order `package.config`
/// reports them: the directory separator, the list separator, the substitution
/// mark, the executable mark and the version mark.
fn package_config() -> String {
  dirsep() + "\n;\n?\n!\n-\n"
}

///|
/// Whether the state was built to ignore environment variables (`-E`).  The
/// reference keeps the flag in the registry, which is where `noenv` reads it.
fn noenv(state : @core.LuaState) -> Bool {
  state.registry.get_str("LUA_NOENV").is_truthy()
}

///|
/// Replaces every `!` of a path template with the directory of the running
/// executable, the reference's `setprogdir`.
fn set_prog_dir(path : String) -> String {
  if @host.lua_mbt_is_windows() != 0 {
    path.replace_all(old="!", new=exec_dir())
  } else {
    path
  }
}

///|
/// Puts the value of `package[field]` in place, the reference's `setpath`.  The
/// versioned environment variable is looked at first (`LUA_PATH_5_4`), then the
/// plain one (`LUA_PATH`); a state built with `-E` ignores both.  A value that
/// holds `;;` gets the default templates where its first `;;` is, which is what
/// makes `LUA_PATH='mylib/?.lua;;'` mean "my library and then the usual ones".
fn set_path(
  state : @core.LuaState,
  pkg : @core.LTable,
  field : String,
  envname : String,
  dft : String,
) -> Unit {
  let from_env = match @oslib.os_env(envname + "_5_4") {
    Some(v) => Some(@core.text_of(v))
    None =>
      match @oslib.os_env(envname) {
        Some(v) => Some(@core.text_of(v))
        None => None
      }
  }
  let path = if noenv(state) {
    dft
  } else {
    match from_env {
      None => dft
      Some(p) =>
        match p.find(";;") {
          None => p
          Some(i) => {
            let prefix = p[:i].to_owned()
            let suffix = p[i + 2:].to_owned()
            let head = if prefix == "" { "" } else { prefix + ";" }
            if suffix == "" {
              head + dft
            } else {
              head + dft + ";" + suffix
            }
          }
        }
    }
  }
  pkg.set_str(field, @core.VStr(@core.LStr::of_string(set_prog_dir(path))))
}

///|
/// Looks for the module `name` in the template list `path`.  Returns the file
/// found, or none and the message `searchpath` reports: the list with every
/// template's `?` replaced by the name and its separators turned into the lines
/// that name them, so an empty template is reported as an empty name
/// (`searchpath`/`pusherrornotfound` in the reference).
fn search_path(
  name : String,
  path : String,
  sep : String,
  rep : String,
) -> (String?, String) {
  // `luaL_gsub` replaces every occurrence of the separator, not the first.
  let file = if sep != "" { name.replace_all(old=sep, new=rep) } else { name }
  let pathname = path.replace_all(old="?", new=file)
  for candidate in pathname.split(";") {
    let c = candidate.to_owned()
    if file_exists(c) {
      return (Some(c), "")
    }
  }
  (
    None,
    "no file '" + pathname.replace_all(old=";", new="'\n\tno file '") + "'",
  )
}

///|
/// Whether a path names an existing file.  The name is handed to the host as it
/// is: whether it can be a name at all is the host's business.
fn file_exists(path : String) -> Bool {
  let h = @host.lua_mbt_fopen(@core.bytes_of(path), @core.bytes_of("rb"))
  if h == 0L {
    false
  } else {
    let _ = @host.lua_mbt_fclose(h)
    true
  }
}

///|
/// `findfile` reads the path a searcher is about to use with `lua_tostring`,
/// which takes a number as the text of that number and refuses anything that is
/// neither a string nor a number.  So `package.path = 5` is not an error: it
/// searches for a file called `5`.
fn path_field(
  state : @core.LuaState,
  field : String,
) -> String raise @core.LuaRaised {
  match @load.package_self(state).get_str(field) {
    @core.VStr(s) => @core.text_of(s.data())
    v =>
      if v.is_number() {
        @core.text_of(@vm.to_string(state, v))
      } else {
        @core.runtime_error(state, "'package." + field + "' must be a string")
      }
  }
}

///|
/// `package.searchpath`.
fn pkg_searchpath(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "searchpath")
  let path = @core.check_str(state, args, 2, "searchpath")
  let sep = if args.length() >= 3 && !args[1].is_nil() {
    @core.check_str(state, args, 3, "searchpath").data()
  } else {
    @core.bytes_of(".")
  }
  let rep = if args.length() >= 4 && !args[2].is_nil() {
    @core.check_str(state, args, 4, "searchpath").data()
  } else {
    @core.bytes_of(dirsep())
  }
  let (found, msg) = search_path(
    @core.text_of(name.data()),
    @core.text_of(path.data()),
    @core.text_of(sep),
    @core.text_of(rep),
  )
  match found {
    Some(f) => @core.One(@core.VStr(@core.LStr::of_string(f)))
    None => @core.Two(@core.VNil, @core.VStr(@core.LStr::of_string(msg)))
  }
}

///|
/// The searcher that consults `package.preload`.
fn searcher_preload(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "searcher")
  let preload = @load.package_table(state, "preload")
  match preload.get(@core.VStr(name)) {
    @core.VNil =>
      @core.Many([
        @core.VStr(
          @core.LStr::of_bytes(
            @core.bytes_concat([
              @core.bytes_of("no field package.preload['"),
              name.data(),
              @core.bytes_of("']"),
            ]),
          ),
        ),
      ])
    // The loader data names where the loader came from, which `require`
    // returns as its second result.
    f => @core.Two(f, @core.VStr(@core.LStr::of_string(":preload:")))
  }
}

///|
/// The searcher that looks for a Lua source file.
fn searcher_lua(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "searcher")
  // A `package.path` that is neither a string nor a number is an error, not a
  // fallback to the default: the reference reports it through `findfile` before
  // searching.
  let path = path_field(state, "path")
  let (found, msg) = search_path(
    @core.text_of(name.data()),
    path,
    ".",
    dirsep(),
  )
  match found {
    None => @core.One(@core.VStr(@core.LStr::of_string(msg)))
    Some(file) => {
      let data = match @core.read_whole_file(@core.bytes_of(file)) {
        Ok(d) => d
        Err(e) =>
          return @core.Many([
            @core.VStr(
              @core.LStr::of_bytes(
                @core.bytes_concat([
                  @core.bytes_of("cannot read "),
                  @core.bytes_of(file),
                  @core.bytes_of(": "),
                  e,
                ]),
              ),
            ),
          ])
      }
      match
        @load.compile_source(
          state,
          data,
          "@" + file,
          @core.VTable(state.globals),
        ) {
        @core.LoadOk(f) => @core.Two(f, @core.VStr(@core.LStr::of_string(file)))
        // A module that does not compile is reported as a failure to load it
        // (`checkload`), not as the bare syntax error.
        @core.LoadError(msg) =>
          @core.runtime_error(
            state,
            "error loading module '" +
            @core.text_of(name.data()) +
            "' from file '" +
            file +
            "':\n\t" +
            @core.text_of(msg),
          )
      }
    }
  }
}

///|
/// What the host loader said the last time it refused something.  The failing
/// call saves the message in C rather than letting MoonBit ask for it later:
/// on Windows the error belongs to the call that failed, and anything run in
/// between would overwrite it.  See the note in `stub.c`.
///
/// The answer stays **bytes**.  It is the host's own text, and on Windows that
/// means the system codepage rather than UTF-8 -- the reference passes those
/// bytes on untouched, and reading them as a `String` would replace whatever
/// this machine's codepage spelled with the replacement character.
fn dl_error() -> Bytes {
  let size = 512
  let buf = Bytes::new(size)
  let n = @host.lua_mbt_dl_error(buf, size)
  @core.bytes_slice(buf, 0, n)
}

///|
/// Opens a shared library and answers with its handle, or with the loader's
/// reason.  0 is "no library", the same way 0 is "no file" for a stream handle.
fn dl_open(path : String) -> (Int64, Bytes) {
  let h = @host.lua_mbt_dl_open(@core.bytes_of(path))
  if h == 0L {
    (0L, dl_error())
  } else {
    (h, @core.bytes_of(""))
  }
}

///|
/// Looks `name` up in an open library.  The caller owns the handle either way,
/// and nothing in this build can call what comes back.
fn dl_sym(h : Int64, name : String) -> (Int64, Bytes) {
  let p = @host.lua_mbt_dl_sym(h, @core.bytes_of(name))
  if p == 0L {
    (0L, dl_error())
  } else {
    (p, @core.bytes_of(""))
  }
}

///|
/// How far the loader gets: the library opens and the entry is there, but this
/// build has no way to call a function it did not bind at compile time.  Bytes
/// because it goes where the loader's own reason goes.
let cannot_enter : Bytes = @core.bytes_of(
  "dynamic libraries cannot be entered by this build",
)

///|
/// The three answers `ll_loadlib` gives when the library was not found: nothing,
/// the reason, and which step failed.
fn loadlib_failed(message : Bytes, what : String) -> @core.BuiltinResult {
  @core.Many([
    @core.VNil,
    @core.VStr(@core.LStr::of_bytes(message)),
    @core.VStr(@core.LStr::of_string(what)),
  ])
}

///|
/// `package.loadlib`.  The host loader is really asked, so a file that will not
/// open answers with the loader's own reason and `"open"`, and a library that
/// opens but has no such entry answers with `"init"` -- both as the reference's
/// `lookforfunc` does.  What this build cannot do is *enter* the function it
/// finds: MoonBit binds a C symbol by name at compile time and the runtime gives
/// no way to call a pointer read out of a library.  A successful lookup is
/// therefore reported the way a build without a loader reports itself: `nil`, a
/// message that says what stopped it, and `"absent"`.
fn pkg_loadlib(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let path = @core.check_str(state, args, 1, "loadlib")
  let sym = @core.check_str(state, args, 2, "loadlib")
  let (lib, why) = dl_open(@core.text_of(path.data()))
  if lib == 0L {
    return loadlib_failed(why, "open")
  }
  let (entry, why2) = dl_sym(lib, @core.text_of(sym.data()))
  let _ = @host.lua_mbt_dl_close(lib)
  if entry == 0L {
    loadlib_failed(why2, "init")
  } else {
    loadlib_failed(cannot_enter, "absent")
  }
}

///|
/// A declared signature: the tags that name the call shape, and the C symbol.
priv struct CSig {
  ret : Int
  arity : Int
  t1 : Int
  t2 : Int
  sym : String
}

///|
/// The types this build can put in a call, tagged as `stub.c` tags them.  There
/// is no `bool`, no pointer and no struct: each would need a shape built here,
/// and a shape nobody asks for is code nobody checked.
fn c_type_tag(name : String) -> Int? {
  match name {
    "int" => Some(1)
    "int64" => Some(2)
    "double" => Some(3)
    "string" => Some(4)
    _ => None
  }
}

///|
/// The argument's C type, or `void` for a return.
fn c_ret_tag(name : String) -> Int? {
  if name == "void" {
    Some(0)
  } else {
    c_type_tag(name)
  }
}

///|
fn is_space(c : Int) -> Bool {
  c == 32 || c == 9 || c == 10 || c == 13
}

///|
fn is_name_char(c : Int) -> Bool {
  (c >= 65 && c <= 90) ||
  (c >= 97 && c <= 122) ||
  (c >= 48 && c <= 57) ||
  c == 95
}

///|
fn is_name_start(c : Int) -> Bool {
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
}

///|
fn skip_space(b : Bytes, from : Int) -> Int {
  let mut i = from
  while i < b.length() && is_space(b[i].to_int()) {
    i = i + 1
  }
  i
}

///|
/// Read the identifier starting at `i`; the second value is where it stopped, so
/// an empty answer is `i` itself.
fn read_name(b : Bytes, i : Int) -> (String, Int) {
  let mut j = i
  while j < b.length() && is_name_char(b[j].to_int()) {
    j = j + 1
  }
  (@core.text_of(@core.bytes_slice(b, i, j - i)), j)
}

///|
/// `<return> <symbol>(<type>, ...)`, spelled the way C spells it.  The name is
/// what is looked up in the library, so the declaration is also the answer to
/// "which entry?" -- there is no separate symbol argument to disagree with it.
fn parse_sig(src : String) -> Result[CSig, String] {
  let b = @core.bytes_of(src)
  let n = b.length()
  let (ret_name, p1) = read_name(b, skip_space(b, 0))
  if ret_name.length() == 0 {
    return Err(
      "a signature looks like 'double pow(double, double)', with no '*'",
    )
  }
  let (sym, p2) = read_name(b, skip_space(b, p1))
  if sym.length() == 0 {
    return Err(
      "expected a function name between the return type and the '(', as in 'double pow(double, double)'",
    )
  }
  let open = skip_space(b, p2)
  if open >= n || b[open] != b'(' {
    return Err("expected '(' after the function name")
  }
  let ret = match c_ret_tag(ret_name) {
    Some(r) => r
    None =>
      return Err(
        "this build cannot return a '" +
        ret_name +
        "'; the return types are void, int, int64, double, string",
      )
  }
  let types : Array[Int] = []
  let mut i = skip_space(b, open + 1)
  if i < n && b[i] == b')' {
    i = i + 1
  } else {
    for ;; {
      let start = skip_space(b, i)
      if start >= n {
        return Err("expected a type in the argument list")
      }
      let (tname, after) = read_name(b, start)
      if tname.length() == 0 || !is_name_start(b[start].to_int()) {
        return Err("expected a type in the argument list")
      }
      match c_type_tag(tname) {
        Some(t) => types.push(t)
        None =>
          return Err(
            "this build cannot take a '" +
            tname +
            "' argument; the types are int, int64, double, string",
          )
      }
      let next = skip_space(b, after)
      if next < n && b[next] == b',' {
        i = next + 1
      } else if next < n && b[next] == b')' {
        i = next + 1
        break
      } else {
        return Err("expected ',' or ')' in the argument list")
      }
    }
  }
  if skip_space(b, i) != n {
    return Err("unexpected text after the closing ')'")
  }
  // The arity limit is the table's, not the parser's invention.
  if types.length() > 2 {
    return Err(
      "this build can call a function of at most 2 arguments; " +
      sym +
      " takes " +
      types.length().to_string(),
    )
  }
  Ok({
    ret,
    arity: types.length(),
    t1: if types.length() > 0 {
      types[0]
    } else {
      0
    },
    t2: if types.length() > 1 {
      types[1]
    } else {
      0
    },
    sym,
  })
}

///|
/// One argument, read the way the C API reads it: `luaL_checkinteger` for an
/// `int`/`int64` (so a numeric string is accepted and the value is converted as
/// C would), `luaL_checknumber` for a `double`, `luaL_checkstring` for a
/// `string`.  The `LStr` comes back rather than its bytes because the bytes are
/// only borrowed for the duration of the call: a string the coercion made up has
/// to stay alive until the C function is done with it.
fn pack_arg(
  state : @core.LuaState,
  tag : Int,
  args : ArrayView[@core.Value],
  n : Int,
  fname : String,
) -> (Int64, @core.LStr?) raise @core.LuaRaised {
  match tag {
    1 | 2 => (@core.check_int(state, args, n, fname), None)
    3 =>
      (@core.check_number(state, args, n, fname).reinterpret_as_int64(), None)
    _ => (0L, Some(@core.check_str(state, args, n, fname)))
  }
}

///|
/// How far a `string` result is copied.  Longer than this the call reports
/// itself rather than hand back a truncated answer.
let dl_out_size : Int = 4096

///|
/// The callable `package.loadc` answers with: a Lua function that packs its
/// arguments into the shape's slots, makes the call, and reads the answer back by
/// the declared return type.
fn c_callable(sig : CSig, entry : Int64) -> @core.Value {
  let name = sig.sym
  let no_text = @core.bytes_of("")
  fn body(
    state : @core.LuaState,
    upvals : Array[@core.Value],
    args : ArrayView[@core.Value],
  ) -> @core.BuiltinResult raise @core.LuaRaised {
    let _ = upvals
    let mut a0 = 0L
    let mut a1 = 0L
    let mut text0 : @core.LStr? = None
    let mut text1 : @core.LStr? = None
    if sig.arity >= 1 {
      let (v, t) = pack_arg(state, sig.t1, args, 1, name)
      a0 = v
      text0 = t
    }
    if sig.arity == 2 {
      let (v, t) = pack_arg(state, sig.t2, args, 2, name)
      a1 = v
      text1 = t
    }
    // Only a `string` result needs somewhere to be copied to, and the size says
    // as much -- the shape the table answers for is the one that touches `out`.
    let want_text = sig.ret == 4
    let out = if want_text { Bytes::new(dl_out_size) } else { no_text }
    let rc = @host.lua_mbt_dl_call(
      sig.ret,
      sig.arity,
      sig.t1,
      sig.t2,
      entry,
      a0,
      a1,
      match text0 {
        Some(s) => s.data()
        None => no_text
      },
      match text1 {
        Some(s) => s.data()
        None => no_text
      },
      out,
      if want_text {
        dl_out_size
      } else {
        0
      },
    )
    match sig.ret {
      0 => @core.Nothing
      1 | 2 => @core.One(@core.VInt(rc))
      3 => @core.One(@core.VNum(rc.reinterpret_as_double()))
      _ =>
        if rc == -1L {
          // The C function answered with a null pointer, which is a value.
          @core.One(@core.VNil)
        } else if rc < 0L {
          @core.runtime_error(
            state,
            "'" +
            name +
            "' answered a string longer than " +
            dl_out_size.to_string() +
            " bytes",
          )
        } else {
          @core.One(
            @core.VStr(
              @core.LStr::of_bytes(@core.bytes_slice(out, 0, rc.to_int())),
            ),
          )
        }
    }
  }
  // -1 for the parameter count: a C function takes what it was given and ignores
  // the rest, which is also how the reference's `lua_CFunction` behaves.
  @core.VBuiltin(@core.LBuiltin::make(name, -1, body))
}

///|
/// A signature this build cannot express.  Not one of the loader's three answers
/// -- nothing was opened and no entry was looked up -- so it comes back as `nil`
/// and a message, without a step.
fn loadc_rejected(message : String) -> @core.BuiltinResult {
  @core.Many([@core.VNil, @core.VStr(@core.LStr::of_string(message))])
}

///|
/// `package.loadc` -- **this implementation's own extension**, not the
/// reference's: the reference hands back a `lua_CFunction` and calls it against
/// its own `lua_State`, and neither half of that exists here (see the note on the
/// shape table in `stub.c`).  What it does give is a plain C function, found by
/// name in a library named at run time, called through a shape the program
/// declares: `package.loadc("libm.so.6", "double fmod(double, double)")`.
/// Arguments are converted the way the C API converts them, and a `string`
/// argument is borrowed for the duration of the call only.
fn pkg_loadc(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let path = @core.check_str(state, args, 1, "loadc")
  let decl = @core.check_str(state, args, 2, "loadc")
  let sig = match parse_sig(@core.text_of(decl.data())) {
    Err(msg) => return loadc_rejected(msg)
    Ok(s) => s
  }
  let (lib, why_open) = dl_open(@core.text_of(path.data()))
  if lib == 0L {
    return loadlib_failed(why_open, "open")
  }
  let (entry, why_sym) = dl_sym(lib, sig.sym)
  if entry == 0L {
    let _ = @host.lua_mbt_dl_close(lib)
    return loadlib_failed(why_sym, "init")
  }
  // The library is deliberately *not* closed: the function is about to be
  // called, and a library the process has released could have given its pages
  // back.  The reference keeps its libraries for the same reason.
  @core.One(c_callable(sig, entry))
}

///|
/// The searcher for a native module.  A module the host compiled in answers
/// first and needs no file -- this is the slot where the reference would have
/// opened a shared library, and here the loader is handed over directly.
/// Otherwise it looks in `package.cpath` exactly as the Lua searcher looks in
/// `package.path` and reports the same way, which is what makes `require`'s
/// message name the files it tried.  A file that is found ends the search: what
/// comes back is the loader's own reason, raised rather than listed, because the
/// reference has by then found the module's file and only the loading failed.
fn searcher_c(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "searcher")
  let host = state.native_mods.get_lstr(name)
  match host {
    @core.VFunc(_) | @core.VBuiltin(_) =>
      // The loader data names where the loader came from, as ":preload:" does.
      @core.Two(host, @core.VStr(@core.LStr::of_string(":native:")))
    _ => {
      let text = @core.text_of(name.data())
      let cpath = path_field(state, "cpath")
      let (found, msg) = search_path(text, cpath, ".", dirsep())
      match found {
        None => @core.One(@core.VStr(@core.LStr::of_string(msg)))
        Some(file) => search_c_file(state, text, file)
      }
    }
  }
}

///|
/// The fourth searcher, the one that looks for the *root* of a dotted name.  A
/// module called `a.b` need not have a file of its own: the reference takes the
/// part in front of the first dot, looks for `a` in `package.cpath`, and asks the
/// file it finds for the entry `luaopen_a_b` -- so one library can hold a whole
/// tree of modules.  A name with no dot is exactly what the searcher above has
/// already tried, and the reference answers with *nothing* there, which is not
/// the same as answering with a complaint: nothing adds no line to `require`'s
/// report.
fn searcher_croot(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "searcher")
  let text = @core.text_of(name.data())
  match text.find(".") {
    None => @core.Nothing
    Some(i) => {
      let root = text[:i].to_owned()
      let cpath = path_field(state, "cpath")
      let (found, msg) = search_path(root, cpath, ".", dirsep())
      match found {
        None => @core.One(@core.VStr(@core.LStr::of_string(msg)))
        Some(file) => search_croot_file(state, text, file)
      }
    }
  }
}

///|
/// The reference's `searcher_Croot` once the root's file is in hand.  A missing
/// entry is the one answer this searcher keeps as a message rather than an error,
/// and the module it names is spelled *with its dots* -- the entry the file was
/// asked for never appears.  Everything else the file refuses is `checkload`'s,
/// with the module's whole name in it.
fn search_croot_file(
  state : @core.LuaState,
  name : String,
  file : String,
) -> @core.BuiltinResult raise @core.LuaRaised {
  match load_entry(file, openfunc_names(name)) {
    HasEntry => load_error(state, name, file, cannot_enter)
    NoEntry(_) =>
      @core.One(
        @core.VStr(
          @core.LStr::of_string(
            "no module '" + name + "' in file '" + file + "'",
          ),
        ),
      )
    NoLibrary(why) => load_error(state, name, file, why)
  }
}

///|
/// The entry names `loadfunc` asks a file for, in the order it asks them.  A
/// module's dots become underscores, so `a.b` is looked for as `luaopen_a_b`.
/// A name carrying the ignore mark -- `-`, the fifth line of `package.config` --
/// asks for the part in front of it first and falls back on the part behind it,
/// which is how `a-b` ends up in `luaopen_a` rather than in a name no C function
/// could ever have.
fn openfunc_names(name : String) -> Array[String] {
  let modname = name.replace_all(old=".", new="_")
  match modname.find("-") {
    None => ["luaopen_" + modname]
    Some(i) =>
      [
        "luaopen_" + modname[:i].to_owned(),
        "luaopen_" + modname[i + 1:].to_owned(),
      ]
  }
}

///|
/// What the host loader said about a file `package.cpath` turned up.  The two
/// reasons are the loader's own bytes, for the reason given on `dl_error`.
priv enum FileAnswer {
  HasEntry
  NoEntry(Bytes)
  NoLibrary(Bytes)
}

///|
/// The reference's `lookforfunc`: open the file, then ask it for each of the
/// `names` in turn until one is there.  What the callers need is which of the
/// three things happened, not the address -- this build cannot call what it
/// finds.  The library is handed back after the lookup, since nothing is going
/// to be called from it.
fn load_entry(file : String, names : Array[String]) -> FileAnswer {
  match dl_open(file) {
    (0L, why) => NoLibrary(why)
    (lib, _) => {
      let mut last = @core.bytes_of("")
      for n in names {
        match dl_sym(lib, n) {
          (0L, why) => last = why
          _ => {
            let _ = @host.lua_mbt_dl_close(lib)
            return HasEntry
          }
        }
      }
      let _ = @host.lua_mbt_dl_close(lib)
      NoEntry(last)
    }
  }
}

///|
/// `checkload`'s complaint for a file that was found but would not load.  The
/// reference raises it through `luaL_error`, so the search stops right there:
/// what `require` answers is this message rather than the list of files it tried.
fn load_error(
  state : @core.LuaState,
  name : String,
  file : String,
  reason : Bytes,
) -> @core.BuiltinResult raise @core.LuaRaised {
  @core.runtime_error_bytes(
    state,
    @core.bytes_concat([
      @core.bytes_of("error loading module '"),
      @core.bytes_of(name),
      @core.bytes_of("' from file '"),
      @core.bytes_of(file),
      @core.bytes_of("':\n\t"),
      reason,
    ]),
  )
}

///|
/// The reference's `searcher_C` once it has a file.  The entry is either there --
/// and this build stops at "cannot enter what I found" -- or the loader says it
/// is not, with its own reason.  Either way the search does not go on, because
/// the file was found: that is what tells this message apart from the list of
/// files `require` says it looked for.
fn search_c_file(
  state : @core.LuaState,
  name : String,
  file : String,
) -> @core.BuiltinResult raise @core.LuaRaised {
  match load_entry(file, openfunc_names(name)) {
    HasEntry => load_error(state, name, file, cannot_enter)
    NoEntry(why) | NoLibrary(why) => load_error(state, name, file, why)
  }
}

///|
fn open_package_library(state : @core.LuaState) -> Unit {
  let pkg = @load.package_self(state)
  let loaded = @load.package_table(state, "loaded")
  let preload = @load.package_table(state, "preload")
  let searchers = @load.package_table(state, "searchers")
  set_path(state, pkg, "path", "LUA_PATH", default_path())
  set_path(state, pkg, "cpath", "LUA_CPATH", default_cpath())
  pkg.set_str("config", @core.VStr(@core.LStr::of_string(package_config())))
  pkg.set_str(
    "searchpath",
    @core.VBuiltin(@core.LBuiltin::make("searchpath", 4, pkg_searchpath)),
  )
  pkg.set_str(
    "loadlib",
    @core.VBuiltin(@core.LBuiltin::make("loadlib", 2, pkg_loadlib)),
  )
  pkg.set_str(
    "loadc",
    @core.VBuiltin(@core.LBuiltin::make("loadc", 2, pkg_loadc)),
  )
  // The `package` table is reachable both as a field of itself, like the
  // * reference implementation, and through `require`.
  pkg.set_str("loaded", @core.VTable(loaded))
  pkg.set_str("preload", @core.VTable(preload))
  pkg.set_str("searchers", @core.VTable(searchers))
  searchers.set_int(
    1L,
    @core.VBuiltin(
      @core.LBuiltin::make("preload_searcher", 1, searcher_preload),
    ),
  )
  searchers.set_int(
    2L,
    @core.VBuiltin(@core.LBuiltin::make("lua_searcher", 1, searcher_lua)),
  )
  searchers.set_int(
    3L,
    @core.VBuiltin(@core.LBuiltin::make("c_searcher", 1, searcher_c)),
  )
  searchers.set_int(
    4L,
    @core.VBuiltin(@core.LBuiltin::make("croot_searcher", 1, searcher_croot)),
  )
  state.globals.set_str("package", @core.VTable(pkg))
}
