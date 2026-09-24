// Embedding the interpreter in a MoonBit program.
//
//   moon run examples/embed
//
// The public entry points are the ones the command line interface is built
// from: `create` makes a state, `run_string` runs a chunk without ever raising,
// and `pcall_value` calls a value under protection.  See the root README for
// the rest of the surface.

///|
/// A Lua value as text, through the metamethod-aware conversion the language
/// itself uses -- so `__tostring` is honoured, and the state that owns the
/// value is the one it runs in.
fn text(
  state : @core.LuaState,
  v : @core.Value,
) -> String raise @core.LuaRaised {
  @core.text_of(@vm.to_string(state, v))
}

///|
fn main raise {
  let state = @lua.create()

  // A chunk's results come back as an array of Lua values.
  let (ok, results) = @lua.run_string(
    state, "return 6 * 7, 'hello', true", "=embed",
  )
  println("ran a chunk: \{ok}, \{results.length()} result(s)")
  for r in results {
    println("  \{text(state, r)} (\{r.type_name()})")
  }

  // Values the host wants to share go into the globals.
  @lua.set_global(state, "greeting", @lua.value_string("hi from MoonBit"))
  @lua.set_global(state, "limit", @lua.value_int(3L))
  let (ok2, _) = @lua.run_string(
    state, "for i = 1, limit do print(i .. ': ' .. greeting) end", "=embed",
  )
  println("a chunk using host values: \{ok2}")

  // A Lua function can be called from MoonBit, with the arguments converted on
  // the way in and the results on the way out.
  let _ = @lua.run_string(
    state, "function add(a, b) return a + b end", "=embed",
  )
  let add = @lua.global_field(state, "add")
  let (called, sum) = @lua.pcall_value(state, add, [
    @lua.value_int(20L),
    @lua.value_int(22L),
  ])
  println(
    "called a Lua function: \{called}, first result \{text(state, sum[0])}",
  )

  // A failed chunk is reported, not raised: the error object is a Lua value
  // like any other.
  let (ok3, err) = @lua.run_string(state, "error({ code = 42 })", "=embed")
  let code = match err[0] {
    @core.VTable(t) => t.get_str("code")
    other => other
  }
  println(
    "a failing chunk: \{ok3}, the error's code field is \{text(state, code)}",
  )

  // A global written by a chunk is readable from the host.
  let _ = @lua.run_string(state, "answer = add(19, 23)", "=embed")
  let answer = @lua.global_field(state, "answer")
  println("a global the chunk set: \{text(state, answer)}")

  // `call_printed` is what the interactive loop uses: it calls a value with no
  // arguments and sends the results through the Lua `print`, returning the
  // error message on failure and nothing on success.
  let _ = @lua.run_string(
    state, "function show() print('called from MoonBit') end", "=embed",
  )
  let printed = @lua.call_printed(state, @lua.global_field(state, "show"))
  let reported = match printed {
    Some(m) => @core.text_of(m)
    None => "nothing"
  }
  println("call_printed reported: \{reported}")

  // States are independent: a second one starts with its own globals.
  let other = @lua.create()
  let missing = @lua.global_field(other, "answer")
  println("a second state's 'answer' is \{text(other, missing)}")
}
