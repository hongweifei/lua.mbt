# hongweifei/lua

[简体中文](README.md) | English

A Lua 5.4 interpreter written in MoonBit. The lexer, parser, single pass code
generator, register based virtual machine and standard libraries are all
implemented here; the only thing the host provides is what a language runtime
cannot provide for itself — streams, files, the clock, the environment, process
control, `printf` compatible number formatting and a random number generator.
That boundary is `stub.c`, which is the role the C standard library plays for the
reference implementation.

## Quick start

```
moon build --target native --release
```

That builds the interpreter to
`_build/native/release/build/cmd/main/main.exe`, which doubles as the `lua`
command line interface. Run a script, an expression, or the interactive loop:

```
moon run cmd/main -- script.lua arg1 arg2
moon run cmd/main -- -e 'print("hello")'
moon run cmd/main                     # reads stdin; a terminal gets a prompt
```

Run the tests:

```
moon test
```

This port also accepts names written in Chinese (or any UTF-8) for variables,
functions and fields:

```
$ moon run cmd/main -- -e 'local 名字 = "世界"; print("你好，" .. 名字)'
你好，世界
```

The details and the limits are in the identifier entry under
[differences from the reference](#differences-from-the-reference-implementation)
below.

## Examples

`examples/` holds runnable programs. Each one asserts its own results instead of
printing expected output, so running it *is* the test — and each is ordinary Lua
5.4, which is why they also pass through a reference `lua` binary.

| Example | What it shows |
| --- | --- |
| `examples/basics.lua` | the two number subtypes, byte strings, tables, closures, varargs, a tail call, `pcall`/`xpcall` |
| `examples/coroutines.lua` | generators with `coroutine.wrap`, yielding from a metamethod, `coroutine.close` running a pending `<close>` variable |
| `examples/metatables.lua` | operator overloading, a chain of `__index` tables, a read-only proxy, to-be-closed variables |

```
moon run cmd/main -- examples/basics.lua
```

`examples/embed/` is a MoonBit program that embeds the interpreter: it runs
chunks, shares values through the globals, calls a Lua function and reads the
error object of a failing chunk.

```
moon run examples/embed
```

## Layout

Every directory with a `moon.pkg` is one package. The module root holds only
metadata; the executable is in `cmd/main` and the implementation is spread over
seventeen packages under `src`.

| Package | Contents |
| --- | --- |
| `hongweifei/lua` (root) | The embedding interface: the `Lua` handle, the `Value`/`Table` aliases, `ToLua`, `host_function`, `LuaError` (`embed.mbt`, `values.mbt`, `host_functions.mbt`, `errors.mbt`) |
| `src/host` | The host boundary: `extern "c"` declarations in `ffi.mbt` and the `stub.c` that implements them |
| `src/core` | Value model and state: `value`, `objects`, `table`, `table_hash`, `thread`, `userdata`, `state`; numbers (`number`, `number_format`), `opcode`, `bytes`, the `host` services core calls directly, `names` (the names error messages borrow from the running code) and `binop` / `load_outcome` |
| `src/vm` | The interpreter loop and what it dispatches to: `vm`, `vm_frame`, `vm_call`, `vm_instr`, `vm_index`, `vm_arith`, `vm_compare`, `vm_convert`, `vm_hook` |
| `src/compiler` | Scanner (`token`, `lexer`, `lexer_string`), parser (`ast`, `parser`, `parser_expr`, `parser_stat`) and code generation (`funcstate`, `funcstate_regs`, `compiler_entry`, `compiler_expr`, `compiler_call`, `compiler_stat`, `compiler_scope`) |
| `src/chunk` | `string.dump` (`chunk_dump`) and the loader for what it produces (`chunk_undump`) |
| `src/pattern` | Lua pattern matching and the library operations built on it |
| `src/load` | Turning source or a binary chunk into a callable prototype: `state_load`, `base_load` |
| `src/lib/base`, `string`, `math`, `io`, `os`, `table`, `utf8`, `coroutine`, `debug` | One package per standard library |
| `src/lua` | Public entry points: `lua`, `api`, `stdlib`, `lib_package`, and the Lua test suites (`*_test.mbt`) |
| `cmd/main` | The command line interface |
| `examples/embed` | A program that embeds the interpreter; the Lua examples beside it are data files, not a package |

The dependency graph is acyclic:

```
host
 └ core ─┬─ vm
         ├─ compiler
         ├─ chunk
         ├─ pattern
         ├─ load  ← chunk, compiler, vm
         ├─ lib/* ← load, vm, pattern, chunk
         └─ lua   ← lib/*, load, vm
            └ (root) ← core, lua
```

The host boundary is one package, and only five places depend on it directly:
`core` (the host services the interpreter itself needs, which every other
package reaches through its wrappers), `src/lua` (the launcher and `package`'s
search paths), and the three standard libraries that *are* wrappers over host
services -- `lib/io`, `lib/os`, and the random number generator in `lib/math`
(`liolib.c`/`loslib.c`/`lmathlib.c` are thin wrappers over the C library in the
reference the same way).

Values cross package boundaries, so the shared declarations are exported
widely: types, structs, enums, traits and suberrors are `pub(all)`; trait
implementations that other packages rely on are `pub impl`. Methods stay in the
package that declares their type. A few packages set `warnings = "-24"` in their
`moon.pkg` because every standard library entry point carries
`raise LuaRaised` to fit the builtin function type, whether or not that
particular function raises.

`tests/` holds the Lua suites that `moon test` runs through the interpreter, and
`examples/` the runnable programs described above.

## Using it as a library

Embedding it from MoonBit needs one import, `{ "hongweifei/lua" }`: no internal
packages, no `Bytes`, no C-shaped signatures.

```moonbit
let lua = Lua::new()
lua.set("上限", 100)                          // a MoonBit value becomes a global
lua.set_function("平方", fn(args) {           // a MoonBit closure is a Lua function
  match args[0].as_integer() {
    Some(x) => Ok([Value::VInt(x * x)])
    None => Err(Value::text("integer expected"))
  }
})
let total = lua.eval_int("return 平方(3) + 上限")   // Ok(109)
```

`Lua::new` opens every standard library. `run`, `run_file` and `call` answer with
`Result[Array[Value], LuaError]`: a script that fails does not raise a MoonBit
error, and a `LuaError` carries both the **error object itself** (a table raised
by `error({code=42})` can be read field by field) and the text the language
would report for it. `Value` is an alias of the interpreter's own value, so
reading one follows the same rules as the language: `as_integer` is
`math.tointeger`, `raw_equal` is `==`, `as_bytes` gives a string's exact bytes.

Data goes both ways through a pair of traits: `ToLua` moves MoonBit data in (the
scalars, `Array` (a sequence numbered from 1), `Map`, and `Option`, where `None`
is `nil`), and `FromLua` reads it back out -- a table can be taken as a whole as
a `Map[String, T]` or as an `Array[T]` (a sequence, read up to its first absent
field).  **A read names its type in the annotation**, because this language has
no way to write a type argument at a call site; the `eval_*` shorthands below
need none, being the `FromLua` of the types a host asks for most:

```moonbit
let size : Map[String, Int]? = read_lua(lua.get("配置"))     // a table as a map
let items : Array[Int64]? = read_lua(lua.get("清单"))        // a table as a sequence
let limit : Result[Int64, LuaError] = lua.get_as("上限")     // Err says what the language would
let vs = lua.run("return '一', '二'").unwrap()
let words : Result[Array[String], LuaError] = lua.values_as(vs)
```

A failed read complains the way a library function does, and names the value that
is actually wrong: reading `{7, 'x'}` as an `Array[Int64]` says
`number expected, got string` -- about that item, not about the table holding it.
The other direction is one call too: `lua.preload("设置", fn(_) { ... })` makes a
MoonBit module findable by a script's `require("设置")`, whose cache applies as
usual, and the host's own `lua.require("设置")` answers with the same value.
A module a script should not be able to see or replace goes through
`lua.register_module("名字", fn(_) { ... })` instead: it is found by the searcher
the reference reserves for native libraries (the loader's second argument is
`":native:"`, and the result lands in `package.loaded` as usual), but it lives in
no Lua-visible table, so a script can neither list it nor clear it.
A table's own fields and its sequence can also be taken without any conversion,
through `table_entries` and `table_sequence`.

The layers underneath -- `src/lua` and `src/core` -- stay available; the command
line interface is built from them.

The runnable version of the snippet above is `examples/embed/main.mbt`
(`moon run examples/embed`, which asserts its own results), and the same code
runs as a test in `embed_test.mbt` -- a file that uses nothing but this
package's public interface, which is the point of it.

## Implementation notes

* **Numbers.** Integers are 64 bit and wrap around; floats are IEEE doubles. The
  two subtypes are kept apart everywhere, including as table keys, where an
  integral float is normalised to an integer so that `t[1]` and `t[1.0]` denote
  the same slot. Hexadecimal integers wrap around, and decimal integers that do
  not fit become floats, as the language specifies.
* **Strings.** Lua strings are byte sequences, so they are held as `Bytes`
  throughout and never round trip through MoonBit's UTF-16 `String`. Length,
  slicing, pattern matching and comparison are byte oriented.
* **UTF-8 throughout, and in identifiers too.** Strings are bytes, so a Chinese
  comment, a Chinese string literal and the `utf8` library all behave the way
  Lua defines them; on top of that this implementation lets an **identifier** be
  written in UTF-8: a well formed code point outside ASCII is a name character,
  so `local 中 = 1`, `function 打招呼(谁)`, `表.键`, `对象:加一()` and `::再来::`
  all work, as do names mixing scripts (`字母A`, `café`).  That is an
  **extension** over the reference (whose character table stops at ASCII -- see
  the differences below), not ported behaviour.  A chunk read from a *file* may
  also carry a UTF-8 byte
  order mark and a first line starting with `#` (the `#!` line of an executable
  script): both are dropped and the line is replaced by a newline, so line
  numbers do not move -- this is `luaL_loadfilex`'s `skipBOM`/`skipcomment`.  A
  chunk handed to `load` as a string is not stripped that way, because there a
  `#` is the length operator.  `os.date` also hands the host `strftime` one
  conversion specifier at a time, as the reference does, and passes the rest of
  the format through byte for byte, so `os.date("%Y年")` gives `1970年` --
  formatting the whole format in one call loses the text around a multi byte
  character.  A file name is bytes too: a name that reads as
  UTF-8 is handed to the host as UTF-8, which is what makes a Chinese file name
  work on Windows (see the differences below); a name that is not UTF-8 is
  passed through unchanged for the host's own single byte encoding.
* **Execution.** The interpreter loop is iterative: every piece of mutable state
  of a running function lives in a frame record, so a coroutine is suspended by
  returning from the loop and resumed by re-entering it. Native functions are
  frames too, which is what lets `pcall` and `coroutine.yield` behave uniformly
  whether the call they guard is written in Lua or in the host language.
* **Code generation** is a single pass over the tree with an expression
  descriptor and a free register window, following the reference compiler's
  shape. Comparisons and the short circuit operators compile to a value plus an
  explicit conditional jump; calls and `...` stay open until the construct that
  consumes them decides how many results are wanted.
* **Errors** travel as a MoonBit exception and are caught at the protection
  anchors the interpreter installs: a resumed coroutine, or a frame carrying a
  `pcall` continuation. Because the protection lives in the frame rather than on
  the host stack, yielding out of a `pcall` works, and so do nested coroutines.
* **Memory.** Objects are managed by the host runtime, which uses reference
  counting. Cyclic garbage is therefore reclaimed when the process exits.
  `collectgarbage` reports a real allocation figure and honours the usual
  options, but its "collect" cannot free cycles.

## Status

`tools/run_official_tests.mbtx` runs every file of the official 5.4.9 suite
through this interpreter: **28 of the 30 pass**.  The two that do not fail
in exactly the place the reference implementation built on this platform fails,
which was checked by running the same file through it:

* `files` stops at `files.lua:84`, on an assertion about seeking `io.stdin`.  The
  C library's `fseek` on the standard input handle succeeds here, where the test
  expects it to be refused.
* `attrib` stops at `attrib.lua:154`, on `assert(ext == x)` inside
  `try('B', 'B.lua', true, "libs/B.lua")`.  The expected loader data hardcodes a
  forward slash, while `package.config` names the backslash on Windows and every
  path the searchers build uses it.

Both are environment differences rather than differences between the two
implementations, and the suite has a `_port` flag for them: a port that cannot
run its non-portable tests sets it and those blocks are skipped.  This harness
leaves it unset, so the blocks *are* run — they pass apart from the two lines
above.

`files` stops at line 84, so everything after it — including the byte-order-mark
and `#`-first-line cases at `files.lua:537`–`550` — is not reached on this path.
That block run on its own passes under both implementations, and
`tests/language.lua` pins the same four cases.  The same `files.lua` with stdin
closed (`exec 0<&-`) gets this implementation as far as `files.lua:202`, which
asks a `dofile` to yield (`coroutine.wrap(dofile)`): here that reports "attempt
to yield across a C-call boundary" where the reference yields.  That is a known
gap, not something this round changed.

The last two files of the suite need a word.  `cstack` runs its real work (the
`if T then` block at its end is the part that needs the reference's C test
library) and passes.  `api` tests the C API, which an implementation in another
language cannot expose: it guards its whole body with `if T==nil then ... return
end`, so *both* implementations skip it and report success.  Adding it to the
harness runs every file the suite has; it is not independent evidence.

What the interpreter does, in the areas the suite exercises hardest:

* **A real collector.** `collectgarbage` marks from the roots, follows the
  rules that need reachability — weak tables, ephemerons, `__gc` finalization in
  the reference's order — and runs by itself as a program allocates.  Memory
  belongs to the host runtime, which reclaims it by reference counting, so the
  collector decides what is *reachable* rather than freeing anything; a cycle
  still ends with the process.  `collectgarbage("count")` reports the bytes the
  live set holds, strings included, measured by walking it.
* **Resumable host calls.** A `coroutine.yield` that happens while a host
  function is still on the stack — inside `__pairs`, a `__close` handler, a
  metamethod — rides the error channel out and back, and the instruction that
  started the call is finished on resume rather than re-run.
* **`debug` fidelity.** The line traces, level counting, tail calls, traceback
  naming and abbreviation, and the fields of `debug.getinfo` agree with a
  reference build, instruction for instruction.
* **Two budgets.** An uncaught error is reported with a traceback, a program
  that allocates without end is refused with the reference's "not enough memory"
  rather than taking the process down, and a recursion through host callbacks is
  refused with "C stack overflow" when the host stack is nearly spent rather than
  running the real stack out (both are in the differences below).

## Differences from the reference implementation

* **A program is refused past one gigabyte of live data** with the reference's
  "not enough memory" (`MEMORY_LIMIT` in `src/core/state.mbt`).  The reference
  has no such figure: its allocator fails when the host cannot give it more,
  which on a large machine is many gigabytes later.  Memory here is owned by the
  host runtime, which cannot refuse gracefully, so the interpreter keeps its own
  budget.  It is one constant.
* **`collectgarbage("setstepmul", m)` does shape a step here**, though the ledger is this implementation's own.  It scales the work one step is worth, in the direction the reference takes (`incstep` multiplies the debt by it): a larger multiplier finishes a cycle in fewer calls and a smaller one in more (measured: 5000 takes 2 calls, 50 takes 200; the default of 100 leaves everything as it was).  The reference's own stepmul effect is about 1%, because its debt and credit dominate, so the absolute counts still differ.  A parameter is stored as a multiple of four, as the reference stores it (`GCPARAM_ADJ`), so `setstepmul(50)` reports 48 next time; where the reference's byte-sized slot makes a very large parameter wrap, this keeps the value and clamps instead.

* **The `collectgarbage("step")` ledger now follows the reference's debt arithmetic, but the figures are still this implementation's own.**  It simulates `incstep`: a sized step reaches the collector only through `luaC_checkGC`, which steps only while the debt is positive -- so a step taken while the credit from the last collection is unpaid does **nothing at all**; once it is paid, a step pays for "the debt plus the granularity" of work, which is why `size == 0` has room for a whole small cycle (`true` on a fresh heap) and answers `false` on a large one (it used to answer `true` always).  `dosteps(2/10/100/20000)` measures **883/176/18/1** against the reference's **968/194/20/1** (about 9% apart), with the same ordering and `dosteps(20000) == 1`; `setstepmul` points the same way (5000 -> 875, 50 -> 893) and, as there, matters little (about 1%).  The rest of the difference is that this implementation's "one cycle's work" estimate (objects plus bytes over 16) is not the reference's per-object cost, so a few boolean sequences (whether a second `step 0` on a large heap finds the cycle finished) differ.  `count` reports the bytes the collector measured the live set to hold and now also carries the **objects a library function has made since the last cycle**, so it rises with allocation and falls when a cycle runs; the absolute figures differ, because the reference's figure is its allocator's own.

* **Binary chunks are not interchangeable with the reference's.**  The header is
  byte for byte the same — signature, version, format, machine word sizes and the
  two test constants — because that is what decides whether a chunk is source or
  precompiled and how a corrupted one is reported.  The prototype encoding that
  follows is this interpreter's own, so a chunk written here is not readable by
  `lua`, and vice versa.
* **The spelling of the special float values** is fixed to `nan`, `inf` and
  `-inf` for `tostring` rather than following the host `printf`, whose spelling
  differs between C libraries.  `string.format` with `%f`, `%g`, `%e`, `%a` and
  `%A` is passed to the host formatter unchanged, so those look like whatever
  the C library prints: a Windows build of the reference would print what this
  one prints (`-nan(ind)`, `0x1.0000000000000p+0`), while a build against
  another C library prints `nan` and `0x1p+0`.
* **The length of a table with a hole can be a different border.**  The manual
  defines `#t` as *any* `b` with `t[b] ~= nil` and `t[b+1] == nil`, and the
  number this interpreter answers is always one of those.  Which one the
  reference picks is a by-product of its array/hash split (its `rehash` moves
  integer keys between the two parts), so `{1, nil, 3}` is 3 there and 1 here.
  Anything built on `#` inherits it.  A table that is a proper sequence — the
  case the manual defines — agrees.
* **An argument error whose function cannot be named says `?`**, as in the
  reference: the name comes from the call site or from a search of
  `package.loaded`, never from the name a function was registered under.  So a
  file method reached as a value, `pcall(f.read, f, "x")`, reads
  `bad argument #2 to '?' (invalid format)`.
* **The version banner is this implementation's own.**  `lua -v` prints
  `Lua 5.4  (MoonBit implementation)` where the reference prints its copyright
  line.  `_VERSION` is `"Lua 5.4"`, and a program that reads the banner text is
  the only thing that would see the difference.
* **`package.loadlib` finds no `lua_CFunction` and cannot call one.**  The host
  loader really is asked (`dlopen`/`dlsym` on POSIX, `LoadLibraryExA`/
  `GetProcAddress` on Windows), so a file that will not open answers `"open"` and
  one that opens without the entry answers `"init"`, each with the loader's own
  reason.  Only *calling* the function is impossible: the reference pushes a
  `lua_CFunction` as a value and calls it with its own `lua_State`, and this build
  has neither a `lua_State` on the C side -- that would be the interpreter written
  again in C -- nor any way for a library to call back into MoonBit, since the
  native runtime exports no way to call a pointer read out at run time.  So when
  both the file and the entry turn up the answer is
  `nil, "dynamic libraries cannot be entered by this build", "absent"`.  What
  *can* be called is a plain C function, in the next item.  A module written below
  Lua, for a script to `require`, is `Lua::register_module` (see "Using it as a
  library").
* **`package.loadc` is this implementation's own extension.**  It calls a plain C
  function through a signature the program declares:

  ```lua
  local pow = assert(package.loadc("libm.so.6", "double pow(double, double)"))
  print(pow(2, 10))                                    -- 1024.0
  local strcmp = assert(package.loadc("libc.so.6", "int strcmp(string, string)"))
  print(strcmp("abc", "abc"))                          -- 0
  local find = assert(package.loadc("libc.so.6", "string strchr(string, int)"))
  print(find("abcdef", string.byte("c")), find("abcdef", 0))  -- cdef  nil
  ```

  The second argument is a whole C declaration rather than a symbol name: the name
  in it is what gets looked up in the library, and the types say how to pack the
  arguments and read the answer.  The types are `int` (C `int`, 32 bits), `int64`
  (C `int64_t`/`long long`/`size_t`/pointer width), `double` and `string`.  A
  `string` argument lends the Lua string's bytes **for the duration of the call**
  (a library that keeps it must copy it, and an embedded NUL ends it); a `string`
  result is copied up to its NUL -- past 4096 bytes the call reports itself rather
  than truncating, and a NULL answer is `nil`.  A `void` result answers with no
  values.  **At most two arguments**: every callable shape has to be built in C,
  which is the price of the backend having no call-by-pointer, and
  return-type × argument-type combinations already make 105 shapes -- a third
  argument would make it 500.  `bool`, `float`, structs and longer argument lists
  are not in the table, and the parser names whichever part of the signature it
  cannot take.  Failure stays soft and keeps `loadlib`'s shape: `nil, reason`, or
  `nil, reason, "open" | "init"`.  The reference has no such function, so
  `tests/native_libs.lua` joins the UTF-8 suite as a **non-portable** one.
* **An identifier may hold non-ASCII code points: this implementation's own
  extension.**  The reference's `lislalpha` knows only ASCII (its
  `luai_ctype_` table covers 0x00-0x7F), so any byte of 0x80 or more in a
  source file cannot be part of a name and the chunk is refused with
  `<name> expected near '<\228>'` -- `utf8`, a string literal, a comment and
  `os.setlocale` all fail to change that, because the check is not the C
  library's `isalpha`.  Here one well formed UTF-8 code point is one name
  character, so `local 中 = 1`, `function 打招呼(谁) end`, `表.键`,
  `对象:加一()` and `::再来::` can be written, with two byte (`café`), three
  byte (a CJK character) and four byte (an emoji) names.  Three limits:
  **UTF-8 only** (GBK's 你 is `C4 E3`, two lead bytes in a row, and is still
  refused with `<name> expected`); the code point must be **valid** (a
  truncated sequence, an overlong one, a surrogate and anything past U+10FFFF
  do not count, and fall back to the ASCII reading); and an **invisible** code
  point is not a name character either -- a byte order mark (U+FEFF), a zero
  width joiner or space, a bidi control, a line separator, a C1 control and the
  U+_FFFE/U+_FFFF noncharacters all stay out, so the mark in a chunk handed to
  `load` as a string is refused with `unexpected symbol near '<\239>'` exactly
  as the reference refuses it (only a chunk read from a *file* has it stripped,
  by `luaL_loadfilex`).  A non-ASCII character
  right after a numeral **is** absorbed by it, giving the reference's
  `malformed number near '100万'` rather than `100` and a stray name (the old
  behaviour for an ASCII letter is byte for byte unchanged).  **No valid
  program changes meaning**: in real Lua a byte outside ASCII appearing outside
  a string or a comment is already a syntax error, so this only turns input that
  used to be refused into something usable -- and it does not quietly turn a
  refused byte order mark into a legal identifier -- while `load`/`require`/file
  names are unaffected.  For the reference's strictness -- a portability check,
  say -- run the reference's own `lua`; there is no switch here that turns the
  extension off.  An ASCII name costs one extra compare on the lexer's hot path:
  an in-process A/B (a name-free control in the same process, so its own drift
  divides out) measured the ratio 0.431 -> 0.429, inside the noise.
* **A file name is handed to the host as UTF-8, which opens names the reference
  cannot open.**  A Windows file name is UTF-16 while a Lua string is bytes.
  When the name is valid UTF-8 it is converted to wide characters and passed to
  `_wfopen`/`_wremove`/`_wrename`, so `io.open("中文.txt")`, `dofile("脚本.lua")`
  and `require("模块")` written in a source file open the Chinese file names
  they name; a Windows build of the reference uses the narrow API and reports
  "No such file or directory" for the same code.  A name that is not valid
  UTF-8 is still passed to the narrow API **as it is** (the host's own encoding
  keeps working: a file `io.open` creates under such a name is found by
  `loadfile` under the same one), so this only opens names that did not open
  before and cannot break one that did.  A name is carried as **bytes**
  throughout and never rounded through a MoonBit `String`, so it cannot be
  replaced by a lossily decoded one.  Other platforms have no such conversion --
  there a file name is bytes to begin with.
* **It is slower than the reference, by a factor that depends on the work.**  `tools/run_bench.mbtx` measures it on this machine: both sides run the same cases and have to agree on every checksum, `--repeat=N` decides how many times each case runs (three by default) and the fastest run is the one reported -- the absolute seconds of one and the same binary can differ by a factor of two between runs, so **only the ratios are trustworthy** and the absolute figures come as a range.  The figures below come from `--repeat=5`.  The ratios now: coroutines 0.8-1.0x (this implementation is the faster one there), plain pattern searching 0.7-1.5x, allocation-heavy `table-small` 2.7x and `string-build` 5.3x, table operations 6.7-8.4x, strings 11-15x, and arithmetic and bitwise work 9-23x (worst: `calls`, about 16x); the ratios whose reference side is tiny (often 2-4 ms) swing a lot, which is why these are ranges.  The latest round made the interpreter loop's **stack accesses that an instruction's own operands bound unchecked** (`base + inst.a/b/c` are inside the frame's window, which `push_frame` reserved for the whole prototype; wherever the value may call back into Lua and so reallocate the stack, the value is computed first and stored after, leaving no question of evaluation order).  In-process A/B, interleaved in one session: `MOVE` **14.3 -> 12.1 ns** (-15%), an integer addition **24.4 -> 19.7** (-19%), an integer-keyed table read **28.7 -> 25.3** (-12%); a string-keyed read gained only 3% (its cost is the hash probe) and `call0` only 3% (the call path is not stack-access bound).  End to end on a quiet machine: `calls` 0.058 -> **0.048 s**, `arith-int` 0.094 -> **0.084**, `arith-float` 0.029 -> **0.026**, `table-hash` 0.062 -> **0.059**, `string-rep` 0.051 -> **0.045**, `coroutine-switch` 0.087 -> **0.078**, most cases -8…-19%.  This round **inlined the integer and float cases of `+`, `-` and `*` into the dispatch loop**, leaving everything else (a string operand to coerce, a metamethod, the error) to `arith`, which stays the one definition of what those operators mean: `arith-int` **-12%…-15%** back to back, `arith-float` -6%…-9%, `arith-bits` unmoved (bitwise operations were not inlined, which is the control), and the other cases within ±9%, which is code-layout noise.  The per-instruction fixed cost is still the bottleneck (measured: a `MOVE` about 10-17 ns, an integer addition 25 ns, an integer-keyed table read 27-31 ns), and the string-keyed lookup has since been attacked once: reading a global used to cost about 180-215 ns where an integer-keyed read costs 27-31 ns, and a component probe put about 55 ns of that in **making a fresh `Key` box per lookup** and about 20 ns in hashing.  **The route tried at the time was making `Key` a `#valtype`, and that route does not work**, though -- a `Key` holds a `Value`, so it cannot be a `#valtype`, and all the rewrite achieved was trading one box for another plus a branch (the payoff of not building the key had to wait for a different shape, further down).  What was removable is the `Hasher`: it has a `mut` field, so it is a heap object, and **every call that hashed a key allocated one**.  So `key_hash` now answers a string with the content hash `LStr` already computed and cached (every table goes through that one function, which is what keeps the slots consistent).  In-process A/B/A, interleaved in one session, three runs each, fastest of each: `get_lstr` **105-113 -> 67-90 ns**, `set_lstr` **115 -> 72-78 ns**, with the integer-keyed control flat (100-110 ns in both arms).  The end-to-end benchmark gave no usable figure this round: the machine was busy while it ran, and even the reference side was 30-50% slower, so those absolute numbers are not worth quoting.  Measured **back to back** against the previous state (one run, one machine, fastest run), this round made arithmetic 2.2-4.7x faster (`arith-float` 4.7x), `calls` 2.5x and the table cases 1.1-1.6x by taking the heap allocations out of every operation and every call: `Value` is a `#valtype` now (the native backend compiles it to a real tagged C union, 16 bytes, unboxed, so a slot read or write no longer allocates), arithmetic and comparison read their operands directly instead of going through a conversion helper that answers with an `Option` (an `Option` boxes its payload on this backend), an ordinary return no longer builds a list for its results (`Results` says "the values are already in the registers"), and a frame no longer allocates the two lists it will not use (protections and to-be-closed variables).  A round after that took `string.gsub` from the worst case (25-36x) to 16x: the replacement is written straight into the result buffer (which is the shape of the reference's `add_s`) instead of a string being built per match, and no capture list is built where the replacement cannot name one -- **2x** measured back to back.  Taking a substring became one allocation and one `memcpy`, where it used to go through a `Buffer` and allocate three times and copy twice.  The round before that gave table access a fast path (the shape of the reference's `luaV_fastget`/`luaV_fastset`): an integer or a string key is read and written as it is instead of being normalised into a `Key` first, and a table with no metatable is written directly -- nothing is looked up before the store, and nothing is charged for it unless the table grew.  Storing and reading the array part is 1.6-3x faster for it (the benchmark's `table-array` went from ~16x to 7.5x), and the shifting part of `table.insert`/`remove` about 3.5x.  The latest round replaced the builtin-call ABI -- the "argument list" and "result list" mentioned just above *were* the shape of it: the arguments are no longer copied into a list (the body is handed an `ArrayView` of its register window, and the frame only records how many there were), and the results are no longer a list built per call (`BuiltinResult`'s `Nothing`/`One`/`Two` are written into the frame's own registers -- the slots the arguments occupied, which is where the reference's C functions push their results -- and only a many-valued answer carries a list).  One builtin call is **39%** faster for it (`math.abs`), **44%** (`next`, two results) and **14%** (`string.sub`, three arguments); end to end that is 0-10% on these benchmarks, most of whose time is the loop and the bytecode rather than such a call.  What is left is still structural, and still not the allocator: the backend is a one-pass C compiler that neither inlines nor allocates registers, so every helper call and every slot move is a real call.  The latest round took integer keys -- lookups of the indices the array part cannot answer -- which used to cost **two heap allocations**: a `Hasher` (it has a `mut` field, so it is a heap object) and a `KInt` box.  The former now comes straight from core's inlined `Hash::hash`, whose accumulator lives on the stack; the latter is gone thanks to a new probe, `probe_int`, which takes the raw `Int64` instead of building a `Key` to search for an integer, and which `get_int`/`set_int`/`next`/`raw_len`/`migrate_following` all go through -- a box is built only when there is something to insert.  In-process white-box A/B (one session, nine rounds each, fastest kept; the array-part control flat at 2 ns): an integer-keyed table read **103 -> 41 ns (-60%)**, of which the `Hasher` was about 31 ns and the `KInt` box about 32 ns, while the hash arithmetic alone (`hash_nobox`) is 1 ns -- **what this round removed is allocations, not hashing**.  The change was checked constructor by constructor: the new and old hashes of `KInt`/`KNum`/`KBool`/`KObj`/`KNil`/`KEmpty` are **bit-identical**, so no slot and no `next` order moved by a byte, and a permanent white-box test pins the equivalence of the two probes (cleared slots included, and the `for_next` case `next` needs).  The five benchmark cases contain no integer hash key, so they serve only as a regression control: five back-to-back runs against the previous binary all landed in 0.8-1.2 with no consistent direction (even `calls`, which this round cannot touch, read 1.2 once), i.e. no measurable regression.
* **How deep a recursion through host callbacks may go is set by the host stack that is left, not by a fixed count of levels.**  The reference stops such a recursion (a `string.gsub` replacement function, an `__index` that calls back) with a fixed count of C levels (`LUAI_MAXCCALLS` = 200), assuming a level costs a few hundred bytes.  Here a level costs about 5 KB -- the same backend reason -- so that count sits exactly on the edge of the 1 MB stack, and `cstack.lua`'s metatable case runs the real stack out (a segfault, not an error).  So besides the reference's level count (190), `call_value` measures how much host stack is left (`MIN_HOST_STACK` = 256 KB, from `lua_mbt_stack_left` in `stub.c`: the thread's stack bounds on Windows, `pthread_getattr_np`/`pthread_get_stackaddr_np` on POSIX) and refuses with the reference's own "C stack overflow".  The cost is that **a recursion gets less deep than in the reference** (about 140-190 levels on a 1 MB stack here, where the reference gets about 197), and that the figure depends on the host's stack and on how deep the call site already is; the reference's own test file says the same about `LUAI_MAXCCALLS` and the stack reserved for the program.
* **Cycles are not freed.**  Memory is reclaimed by the host runtime's reference
  counting; the collector decides reachability, which is what weak tables,
  ephemerons and `__gc` need, but it does not sweep.  A cycle therefore stays
  until the process ends.

## Tests

```
moon test
```

* `tests/language.lua`, `tests/stdlib.lua`, `tests/require_test.lua`,
  `tests/examples.lua`, `tests/utf8_identifiers.lua` and `tests/native_libs.lua`
  are Lua programs run through the interpreter from `src/lua/suite_test.mbt` — the
  same black-box shape an embedder would use, so a failure is reported with the
  failing Lua line.  The first four also pass under the reference; **the last two
  do not**, because they are the two extensions above: the reference refuses
  `local 中 = 1` (line 26 of that suite) and has no `package.loadc` to call at all.
  Keeping each in its own file is what keeps the conformance suites and the
  extension suites from polluting each other.
* The remaining tests sit next to the code they pin: the register layout the
  code generator produces (`src/compiler/codegen_wbtest.mbt`), the `printf`
  conversions, the numeral parser and the code point test for a name character
  (`src/core/number_wbtest.mbt`), the
  stripping of a chunk's prefix (a BOM and a `#` first line,
  `src/load/load_test.mbt`), the command line's option table,
  `-l name=module` splitting and a script's varargs
  (`cmd/main/main_wbtest.mbt`), the message shapes a launched script sees
  (`src/lua/launcher_test.mbt`), and the host boundary
  (`src/host/ffi_wbtest.mbt`).
* The official Lua 5.4 test suite is the conformance judge.  It is not
  redistributed here — `tools/run_official_tests.mbtx` needs a copy in
  `lua-5.4.9-tests/`, and the current figures are under `## Status`.
* Performance is measured by `bench/` and `tools/run_bench.mbtx`: each case asserts its own checksum and prints one `bench <name> <seconds> <checksum>` line, and passing a second interpreter turns the output into ratios (`--repeat=N` sets how often each case runs, three by default, keeping the fastest).  Measure back to back before and after a change and compare the **ratios**, never a number from an earlier session.

```
moon run --target native tools/run_bench.mbtx /path/to/reference/lua
```

## License and sources

Apache-2.0; see `LICENSE`.  `NOTICE` carries the attribution that comes with it,
because the behaviour implemented here is Lua's, ported from the reference
implementation under its MIT license.

The port was written by following these sources:

* **Lua 5.4.9**, the reference implementation, for everything observable:
  `lparser.c`/`lcode.c` (the single pass compiler's shape and its syntax error
  messages), `lvm.c`/`ldo.c` (instruction semantics, how a protected call and a
  yield are arranged, the order an unwind closes variables in), `lgc.c` (the
  collector's rules and the order it applies them in), `lauxlib.c` and the
  `l*baselib.c`/`lstrlib.c`/`ltablib.c`/`lmathlib.c`/`loslib.c`/`liolib.c`/
  `lcorolib.c`/`ldblib.c`/`lutf8lib.c` libraries for the argument checks and the
  messages, and `lua.c`/`loadlib.c`/`luaconf.h` for the launcher, the search
  paths and `package`.
* **The Lua 5.4 reference manual**, for what the language promises — and, where
  the manual and the implementation differ, the implementation.
* **The official test suite** as the judge (see `## Tests`).
* **A Lua 5.4.9 binary built from those sources on this machine**, used as the
  differential oracle: every behaviour that was ported was checked by running the
  same file through both implementations and comparing the whole log, rather
  than by reading the sources alone.
