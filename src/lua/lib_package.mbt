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
/// host.  This implementation has no loader for such a file, but the field
/// exists so that programs inspecting it see what a build for this host would.
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
pub fn search_path(
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
/// Whether a path names an existing file.
pub fn file_exists(path : String) -> Bool {
  let h = @host.lua_mbt_fopen(@core.bytes_of(path), @core.bytes_of("rb"))
  if h == 0L {
    false
  } else {
    let _ = @host.lua_mbt_fclose(h)
    true
  }
}

///|
/// `package.searchpath`.
pub fn pkg_searchpath(
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
pub fn searcher_preload(
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
pub fn searcher_lua(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "searcher")
  let pkg = @load.package_self(state)
  // A `package.path` that is not a string is an error, not a fallback to the
  // default: the reference reports it through `findfile` before searching.
  let path = match pkg.get_str("path") {
    @core.VStr(p) => @core.text_of(p.data())
    _ => @core.runtime_error(state, "'package.path' must be a string")
  }
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
/// `package.loadlib`.  This implementation has no loader for shared libraries,
/// so it answers the way a Lua built without one does: `nil`, the message the
/// reference's `DLMSG` gives, and `"absent"` for the step that failed
/// (`LIB_FAIL` on the fallback path).  A program that calls it gets that answer
/// instead of an attempt to call a missing function.
pub fn pkg_loadlib(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let _ = @core.check_str(state, args, 1, "loadlib")
  let _ = @core.check_str(state, args, 2, "loadlib")
  @core.Many([
    @core.VNil,
    @core.VStr(
      @core.LStr::of_string(
        "dynamic libraries not enabled; check your Lua installation",
      ),
    ),
    @core.VStr(@core.LStr::of_string("absent")),
  ])
}

///|
/// The searcher for a native module.  It looks in `package.cpath` exactly as the
/// Lua searcher looks in `package.path` and reports the same way, which is what
/// makes `require`'s message name the files it tried; this implementation has no
/// loader for a shared library, so a file that *is* found is reported as one it
/// cannot load.
pub fn searcher_c(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "searcher")
  let pkg = @load.package_self(state)
  let cpath = match pkg.get_str("cpath") {
    @core.VStr(p) => @core.text_of(p.data())
    _ => @core.runtime_error(state, "'package.cpath' must be a string")
  }
  let (found, msg) = search_path(
    @core.text_of(name.data()),
    cpath,
    ".",
    dirsep(),
  )
  match found {
    None => @core.One(@core.VStr(@core.LStr::of_string(msg)))
    Some(file) =>
      @core.One(
        @core.VStr(@core.LStr::of_string("no native loader for '" + file + "'")),
      )
  }
}

///|
pub fn open_package_library(state : @core.LuaState) -> Unit {
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
  state.globals.set_str("package", @core.VTable(pkg))
}
