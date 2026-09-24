// Library loading.

///|
pub fn open_libraries(st : @core.LuaState) -> Unit {
  @base.open_base_library(st)
  @strlib.open_string_library(st)
  @tablib.open_table_library(st)
  @mathlib.open_math_library(st)
  @oslib.open_os_library(st)
  @iolib.open_io_library(st)
  open_package_library(st)
  @colib.open_coroutine_library(st)
  @utf8lib.open_utf8_library(st)
  @debuglib.open_debug_library(st)
  register_loaded_libraries(st)
}

///|
/// Fills `package.loaded` with the libraries opened above, as
/// `luaL_requiref` does for the reference implementation.  Without this,
/// `require "string"` and friends go looking for a file instead of returning
/// the live module table.
fn register_loaded_libraries(st : @core.LuaState) -> Unit {
  let names = [
    "_G", "package", "coroutine", "table", "io", "os", "string", "math", "utf8",
    "debug",
  ]
  for name in names {
    let v = st.globals.get_str(name)
    match v {
      @core.VNil => ()
      _ =>
        match st.globals.get_str("package") {
          @core.VTable(pkg) =>
            match pkg.get_str("loaded") {
              @core.VTable(loaded) => loaded.set_str(name, v)
              _ => ()
            }
          _ => ()
        }
    }
  }
}
