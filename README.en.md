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
         ├─ load  ← chunk, compiler, host, vm
         ├─ lib/* ← load, vm, pattern, chunk
         └─ lua   ← lib/*, load, vm, host
```

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

```mbt check
///|
test "embedding" {
  let state = create()
  let (ok, results) = run_string(state, "return 6 * 7", "=example")
  assert_true(ok)
  assert_eq(results.length(), 1)
}
```

`create` builds a state with every standard library open. `run_string`,
`run_bytes` and `run_file` never raise: they return whether the chunk succeeded
and either its results or the error object. Below that sit
`try_load`, which compiles source or a binary chunk into a callable value,
`pcall_here`, which calls a value under protection, and `disassemble`, which
prints what the code generator produced. The command line interface is built
from those three.

## Implementation notes

* **Numbers.** Integers are 64 bit and wrap around; floats are IEEE doubles. The
  two subtypes are kept apart everywhere, including as table keys, where an
  integral float is normalised to an integer so that `t[1]` and `t[1.0]` denote
  the same slot. Hexadecimal integers wrap around, and decimal integers that do
  not fit become floats, as the language specifies.
* **Strings.** Lua strings are byte sequences, so they are held as `Bytes`
  throughout and never round trip through MoonBit's UTF-16 `String`. Length,
  slicing, pattern matching and comparison are byte oriented.
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
* **A budget.** An uncaught error is reported with a traceback, and a program
  that allocates without end is refused with the reference's "not enough memory"
  rather than taking the process down (see the differences below).

## Differences from the reference implementation

* **A program is refused past one gigabyte of live data** with the reference's
  "not enough memory" (`MEMORY_LIMIT` in `src/core/state.mbt`).  The reference
  has no such figure: its allocator fails when the host cannot give it more,
  which on a large machine is many gigabytes later.  Memory here is owned by the
  host runtime, which cannot refuse gracefully, so the interpreter keeps its own
  budget.  It is one constant.
* **`collectgarbage("setstepmul", m)` does shape a step here**, though the ledger is this implementation's own.  It scales the work one step is worth, in the direction the reference takes (`incstep` multiplies the debt by it): a larger multiplier finishes a cycle in fewer calls and a smaller one in more (measured: 5000 takes 2 calls, 50 takes 200; the default of 100 leaves everything as it was).  The reference's own stepmul effect is about 1%, because its debt and credit dominate, so the absolute counts still differ.  A parameter is stored as a multiple of four, as the reference stores it (`GCPARAM_ADJ`), so `setstepmul(50)` reports 48 next time; where the reference's byte-sized slot makes a very large parameter wrap, this keeps the value and clamps instead.

* **The answers of `collectgarbage("step")` and the figure of `count` are this implementation's own.**  The reference's `step` reports whether its *phase machine* happened to finish a cycle -- `step 0` answers `true` on a fresh state and `false` after collecting a large heap -- where this answers `true` for `size == 0` always (bounded, and it cannot spin; a faithful attempt at the phase machine is in the working list).  `count` reports the bytes the collector measured the live set to hold, and it now also carries the **objects a library function has made since the last cycle** (tables, closures, threads, file userdata), so it rises with allocation and falls when a cycle runs, as the reference's does; the absolute figures still differ, because its figure is its allocator's own.

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
* **There is no loader for shared libraries**, so `package.loadlib` answers the
  way a Lua built without one does, and the native searcher reports that it has
  no loader for a file it finds.
* **It is slower than the reference, by a factor that depends on the work.**  `tools/run_bench.mbtx` measures it on this machine: both sides run the same cases and have to agree on every checksum, and each case runs three times by default with the fastest run reported -- the absolute seconds of one and the same binary can differ by a factor of two between runs, so **only the ratios are trustworthy** and the absolute figures come as a range.  The ratios: a coroutine switch ~1.3x, allocation-heavy work (`table-small`, `string-build`) 3-6x, table and string operations 12-46x, and arithmetic and dispatch-heavy loops 29-74x (worst: `calls`).  The structural cause is the representation of `Value` -- a 32 byte enum whose largest payload is `LStr` at 24 bytes -- so every slot read and write copies it and pays the host's reference counting.  It is not the allocator, which is why the allocation-heavy cases are the closest.  Plain pattern searching used to be the worst of all (a slice allocated per position and compared: 0.483 s); it now uses the host's `memchr`/`memcmp` and takes 0.004-0.007 s, in the same range as the reference (~1.2x).
* **Cycles are not freed.**  Memory is reclaimed by the host runtime's reference
  counting; the collector decides reachability, which is what weak tables,
  ephemerons and `__gc` need, but it does not sweep.  A cycle therefore stays
  until the process ends.

## Tests

```
moon test
```

* `tests/language.lua`, `tests/stdlib.lua`, `tests/require_test.lua` and
  `tests/examples.lua` are Lua programs run through the interpreter from
  `src/lua/suite_test.mbt` — the same black-box shape an embedder would use, so
  a failure is reported with the failing Lua line.
* The remaining tests sit next to the code they pin: the register layout the
  code generator produces (`src/compiler/codegen_wbtest.mbt`), the `printf`
  conversions and the numeral parser (`src/core/number_wbtest.mbt`), the
  command line's option table and `-l name=module` splitting
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
