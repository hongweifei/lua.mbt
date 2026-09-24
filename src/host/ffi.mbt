// Host bindings.  Every declaration here is implemented in `stub.c`; the

///|
#borrow(buf, fmt)
pub extern "c" fn lua_mbt_fmt_double(
  buf : Bytes,
  n : Int,
  fmt : Bytes,
  v : Double,
) -> Int = "lua_mbt_fmt_double"

///|
#borrow(buf, fmt)
pub extern "c" fn lua_mbt_fmt_int64(
  buf : Bytes,
  n : Int,
  fmt : Bytes,
  v : Int64,
) -> Int = "lua_mbt_fmt_int64"

///|
#borrow(buf, fmt)
pub extern "c" fn lua_mbt_fmt_uint64(
  buf : Bytes,
  n : Int,
  fmt : Bytes,
  v : UInt64,
) -> Int = "lua_mbt_fmt_uint64"

///|
#borrow(buf, fmt)
pub extern "c" fn lua_mbt_fmt_int(
  buf : Bytes,
  n : Int,
  fmt : Bytes,
  v : Int,
) -> Int = "lua_mbt_fmt_int"

///|
#borrow(buf, fmt, s)
pub extern "c" fn lua_mbt_fmt_cstr(
  buf : Bytes,
  n : Int,
  fmt : Bytes,
  s : Bytes,
) -> Int = "lua_mbt_fmt_cstr"

///|
#borrow(s)
pub extern "c" fn lua_mbt_strtod(s : Bytes, len : Int) -> Double = "lua_mbt_strtod"

///|
/// The index of the first `byte` at or after `from`, searching `len` bytes, or
/// -1 when there is none.  This is the C library's `memchr`, which is what the
/// reference implementation searches a plain pattern with.
#borrow(s)
pub extern "c" fn lua_mbt_memchr(
  s : Bytes,
  from : Int64,
  len : Int64,
  byte : Int,
) -> Int64 = "lua_mbt_memchr"

///|
/// Whether `a[ai .. ai+len)` and `b[bi .. bi+len)` hold the same bytes, which
/// is the C library's `memcmp` answering 1 for equal.
#borrow(a, b)
pub extern "c" fn lua_mbt_memeq(
  a : Bytes,
  ai : Int64,
  b : Bytes,
  bi : Int64,
  len : Int64,
) -> Int = "lua_mbt_memeq"

///|
/// Copies `len` bytes from `src + si` into `dst + di`, which is how a substring
/// is made without a buffer in between.
#borrow(dst, src)
pub extern "c" fn lua_mbt_bytes_copy(
  dst : Bytes,
  di : Int64,
  src : Bytes,
  si : Int64,
  len : Int64,
) = "lua_mbt_bytes_copy"

///|
pub extern "c" fn lua_mbt_stdin() -> Int64 = "lua_mbt_stdin"

///|
pub extern "c" fn lua_mbt_stdout() -> Int64 = "lua_mbt_stdout"

///|
pub extern "c" fn lua_mbt_stderr() -> Int64 = "lua_mbt_stderr"

///|
#borrow(path, mode)
pub extern "c" fn lua_mbt_fopen(path : Bytes, mode : Bytes) -> Int64 = "lua_mbt_fopen"

///|
pub extern "c" fn lua_mbt_fclose(h : Int64) -> Int = "lua_mbt_fclose"

///|
pub extern "c" fn lua_mbt_fflush(h : Int64) -> Int = "lua_mbt_fflush"

///|
#borrow(buf)
pub extern "c" fn lua_mbt_fread(h : Int64, buf : Bytes, len : Int) -> Int = "lua_mbt_fread"

///|
#borrow(buf)
pub extern "c" fn lua_mbt_fwrite(h : Int64, buf : Bytes, len : Int) -> Int = "lua_mbt_fwrite"

///|
pub extern "c" fn lua_mbt_fseek(h : Int64, off : Int64, whence : Int) -> Double = "lua_mbt_fseek"

///|
pub extern "c" fn lua_mbt_ftell(h : Int64) -> Int64 = "lua_mbt_ftell"

///|
pub extern "c" fn lua_mbt_feof(h : Int64) -> Int = "lua_mbt_feof"

///|
pub extern "c" fn lua_mbt_ferror(h : Int64) -> Int = "lua_mbt_ferror"

///|
pub extern "c" fn lua_mbt_clearerr(h : Int64) -> Unit = "lua_mbt_clearerr"

///|
pub extern "c" fn lua_mbt_fgetc(h : Int64) -> Int = "lua_mbt_fgetc"

///|
pub extern "c" fn lua_mbt_ungetc(c : Int, h : Int64) -> Int = "lua_mbt_ungetc"

///|
#borrow(buf)
pub extern "c" fn lua_mbt_fgets(h : Int64, buf : Bytes, len : Int) -> Int = "lua_mbt_fgets"

///|
#borrow(path)
pub extern "c" fn lua_mbt_remove(path : Bytes) -> Int = "lua_mbt_remove"

///|
#borrow(from, to)
pub extern "c" fn lua_mbt_rename(from : Bytes, to : Bytes) -> Int = "lua_mbt_rename"

///|
pub extern "c" fn lua_mbt_tmpfile() -> Int64 = "lua_mbt_tmpfile"

///|
#borrow(cmd, mode)
pub extern "c" fn lua_mbt_popen(cmd : Bytes, mode : Bytes) -> Int64 = "lua_mbt_popen"

///|
pub extern "c" fn lua_mbt_pclose(h : Int64) -> Int = "lua_mbt_pclose"

///|
pub extern "c" fn lua_mbt_setvbuf(h : Int64, mode : Int, size : Int) -> Int = "lua_mbt_setvbuf"

///|
pub extern "c" fn lua_mbt_fileno(h : Int64) -> Int = "lua_mbt_fileno"

///|
pub extern "c" fn lua_mbt_errno() -> Int = "lua_mbt_errno"

///|
pub extern "c" fn lua_mbt_set_errno(e : Int) -> Unit = "lua_mbt_set_errno"

///|
#borrow(buf)
pub extern "c" fn lua_mbt_strerror(e : Int, buf : Bytes, n : Int) -> Int = "lua_mbt_strerror"

///|
#borrow(buf)
pub extern "c" fn lua_mbt_tmpnam(buf : Bytes, n : Int) -> Int64 = "lua_mbt_tmpnam"

///|
pub extern "c" fn lua_mbt_time() -> Int64 = "lua_mbt_time"

///|
pub extern "c" fn lua_mbt_clock() -> Double = "lua_mbt_clock"

///|
pub extern "c" fn lua_mbt_diff_seconds(a : Int64, b : Int64) -> Double = "lua_mbt_diff_seconds"

///|
#borrow(out)
pub extern "c" fn lua_mbt_tm_breakdown(
  t : Int64,
  islocal : Int,
  out : Bytes,
) -> Int = "lua_mbt_tm_breakdown"

///|
#borrow(buf, fmt)
pub extern "c" fn lua_mbt_strftime_time(
  buf : Bytes,
  n : Int,
  fmt : Bytes,
  t : Int64,
  islocal : Int,
) -> Int = "lua_mbt_strftime_time"

///|
pub extern "c" fn lua_mbt_time_make(
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  min : Int,
  sec : Int,
  isdst : Int,
  islocal : Int,
) -> Int64 = "lua_mbt_time_make"

///|
pub extern "c" fn lua_mbt_tz_offset(t : Int64) -> Int = "lua_mbt_tz_offset"

///|
pub extern "c" fn lua_mbt_isdst(t : Int64) -> Int = "lua_mbt_isdst"

///|
#borrow(buf)
pub extern "c" fn lua_mbt_getlocale(buf : Bytes, n : Int) -> Int = "lua_mbt_getlocale"

///|
#borrow(locale)
pub extern "c" fn lua_mbt_setlocale(locale : Bytes, category : Int) -> Int = "lua_mbt_setlocale"

///|
pub extern "c" fn lua_mbt_locale_decpoint() -> Int = "lua_mbt_locale_decpoint"

///|
#borrow(a, b)
pub extern "c" fn lua_mbt_strcmp(a : Bytes, b : Bytes) -> Int = "lua_mbt_strcmp"

///|
#borrow(a, b)
pub extern "c" fn lua_mbt_lstrcmp(
  a : Bytes,
  la : Int,
  b : Bytes,
  lb : Int,
) -> Int = "lua_mbt_lstrcmp"

///|
#borrow(name, buf)
pub extern "c" fn lua_mbt_getenv(name : Bytes, buf : Bytes, n : Int) -> Int = "lua_mbt_getenv"

///|
#borrow(name, value)
pub extern "c" fn lua_mbt_setenv(
  name : Bytes,
  value : Bytes,
  overwrite : Int,
) -> Int = "lua_mbt_setenv"

///|
#borrow(name)
pub extern "c" fn lua_mbt_unsetenv(name : Bytes) -> Int = "lua_mbt_unsetenv"

///|
#borrow(cmd)
pub extern "c" fn lua_mbt_system(cmd : Bytes) -> Int = "lua_mbt_system"

///|
/// Whether the host has a command processor, which `os.execute()` with no
/// command asks (`system(NULL)`).
pub extern "c" fn lua_mbt_system_available() -> Int = "lua_mbt_system_available"

///|
/// Whether the host is Windows.  The reference chooses its default package
/// path templates and its directory separator with the same condition.
pub extern "c" fn lua_mbt_is_windows() -> Int = "lua_mbt_is_windows"

///|
/// Whether standard input is a terminal.
pub extern "c" fn lua_mbt_stdin_is_tty() -> Int = "lua_mbt_stdin_is_tty"

///|
/// Writes the directory holding the running executable, without a trailing
/// separator, and returns its length.  -1 when it cannot be found; a buffer
/// that is too small returns the length the answer needs.
#borrow(buf)
pub extern "c" fn lua_mbt_exec_dir(buf : Bytes, n : Int) -> Int = "lua_mbt_exec_dir"

///|
pub extern "c" fn lua_mbt_exit(code : Int) -> Unit = "lua_mbt_exit"

///|
/// Installs the reference generator's state and spreads it, as `setseed`.
pub extern "c" fn lua_mbt_rng_seed(a : UInt64, b : UInt64) -> Unit = "lua_mbt_rng_seed"

///|
/// The two seeds the reference uses when no seed is given: the clock, and an
/// address that changes from run to run.
pub extern "c" fn lua_mbt_rng_time_seed() -> UInt64 = "lua_mbt_rng_time_seed"

///|
pub extern "c" fn lua_mbt_rng_addr_seed() -> UInt64 = "lua_mbt_rng_addr_seed"

///|
pub extern "c" fn lua_mbt_rng_next() -> UInt64 = "lua_mbt_rng_next"

///|
pub extern "c" fn lua_mbt_ctype(which : Int, c : Int) -> Int = "lua_mbt_ctype"

///|
pub extern "c" fn lua_mbt_toupper32(c : Int) -> Int = "lua_mbt_toupper32"

///|
pub extern "c" fn lua_mbt_tolower32(c : Int) -> Int = "lua_mbt_tolower32"

///|
/// How much of the host stack is left below this call, in bytes, or -1 when the
/// host cannot say.  See the note on `lua_mbt_stack_left` in `stub.c`.
pub extern "c" fn lua_mbt_stack_left() -> Int = "lua_mbt_stack_left"
