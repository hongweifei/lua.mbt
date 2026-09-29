// The public MoonBit interface, checked through that interface only: this file
// imports nothing but the root package, which is the claim being tested -- a host
// program should not need the interpreter's own packages to embed it.

///|
/// The number a result carries, or a marker the tests can tell apart from any
/// value a script could answer with.
fn or_missing(r : Result[Int64, LuaError]) -> Int64 {
  r.unwrap_or(-777_777L)
}

///|
/// The text a result carries, or the same kind of marker.
fn or_none(r : Result[String, LuaError]) -> String {
  r.unwrap_or("<missing>")
}

///|
test "a chunk's results, arguments and errors" {
  let lua = Lua::new()
  let vs = lua
    .run("return ...", args=[Value::VInt(7L), Value::text("x)")])
    .unwrap()
  assert_eq(vs.length(), 2)
  assert_eq(vs[0].as_integer(), Some(7L))
  assert_eq(vs[1].as_text(), Some("x)"))

  // A chunk that answers with nothing has no results, not a nil one.
  assert_eq(lua.run("local x = 1").unwrap().length(), 0)

  // A chunk that does not compile is an `Err` carrying the message `load` gives.
  let bad = lua.run("return =", name="=probe")
  assert_true(bad is Err(_))
  assert_true(
    match bad {
      Err(e) => e.message.contains("unexpected symbol near '='")
      Ok(_) => false
    },
  )

  // A runtime failure keeps the error *object*, so a structured error survives
  // the boundary and can be inspected field by field.
  let raised = lua.run("error({ code = 42 })", name="=probe")
  match raised {
    Err(e) => {
      assert_eq(e.message, "(error object is a table value)")
      let code = match e.value {
        Value::VTable(t) => t.get_str("code")
        _ => Value::VNil
      }
      assert_eq(code.as_integer(), Some(42L))
    }
    Ok(_) => fail("a raised table should not be swallowed")
  }

  // A string error carries the position, as it does in the reference.
  match lua.run("error(\"nope\")", name="=probe") {
    // The `=` in a chunk name means "say this, not a file", so the position in
    // a message shows the name without it.
    Err(e) => assert_eq(e.message, "probe:1: nope")
    Ok(_) => fail("the error should come back")
  }
}

///|
test "loading is not running" {
  let lua = Lua::new()
  // The chunk never runs, so its side effect never happens.
  let f = lua.load("touched = true error('never ran')", name="=a").unwrap()
  // Loading made a value and ran nothing.
  assert_eq(lua.get("touched").is_nil(), true)
  // Calling it is what raises, and what the assignment above proves ran.
  assert_true(lua.call(f) is Err(_))
  // A value can still be read by matching on it, since `Value` is the
  // interpreter's own type and its cases are its own.
  match lua.get("touched") {
    Value::VBool(b) => assert_eq(b, true)
    v => fail("a boolean should have arrived, got " + v.type_name())
  }

  let ok = lua.load("return 1 + 1", name="=b").unwrap()
  assert_eq(lua.call(ok).unwrap()[0].as_integer(), Some(2L))
  // A chunk is a vararg function, so `load` then `call` passes arguments in.
  let sum = lua.load("local a, b = ... return a + b", name="=c").unwrap()
  let called = lua.call(sum, args=[Value::VInt(2L), Value::VInt(3L)]).unwrap()
  assert_eq(called[0].as_integer(), Some(5L))
}

///|
test "globals and the conversions both ways" {
  let lua = Lua::new()
  lua.set("n", 3)
  lua.set("big", 9007199254740993L)
  lua.set("ratio", 1.5)
  lua.set("on", true)
  lua.set("name", "世界")
  lua.set("items", [1, 2, 3])
  let cfg : Map[String, Int] = Map::from_array([("a", 1), ("b", 2)])
  lua.set("cfg", cfg)
  lua.set("missing", (None : Int?))
  lua.set("present", (Some(7) : Int?))
  let t = new_table()
  t.set_str("k", Value::VInt(1L))
  lua.set("tbl", t)

  // What Lua itself sees of each of them.
  let probe =
    #|local out = {}
    #|local keys = {
    #|  "n", "big", "ratio", "on", "name", "items", "cfg", "missing",
    #|  "present", "tbl",
    #|}
    #|for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. type(_G[k]) end
    #|return table.concat(out, " ")
  let kinds = lua.run(probe, name="=types").unwrap()
  assert_eq(
    kinds[0].as_text(),
    Some(
      "n=number big=number ratio=number on=boolean name=string " +
      "items=table cfg=table missing=nil present=number tbl=table",
    ),
  )

  // The conversions are the ones the language makes, not a lossy shortcut: an
  // integer stays exact where a float would round.
  assert_eq(or_missing(lua.eval_int("return big")), 9007199254740993L)
  assert_eq(lua.eval_number("return big").unwrap(), 9007199254740992.0)
  assert_eq(or_missing(lua.eval_int("return #items")), 3L)
  assert_eq(or_missing(lua.eval_int("return items[3] + cfg.b")), 5L)
  assert_eq(or_missing(lua.eval_int("return present + n")), 10L)
  assert_eq(or_none(lua.eval_text("return missing")), "<missing>")
  assert_eq(lua.eval_bool("return name").unwrap(), true)
  assert_eq(lua.eval_bool("return missing").unwrap(), false)
  assert_eq(or_none(lua.eval_text("return name")), "世界")

  // The bytes of a string come back exactly, so data that is not text survives.
  let raw = lua.eval_bytes("return string.char(255, 2, 254)").unwrap()
  assert_eq(raw, b"\xff\x02\xfe")
  // Text goes the other way as UTF-8, byte for byte.
  assert_eq(Value::text("世界").as_bytes(), Some(b"\xE4\xB8\x96\xE7\x95\x8C"))
  // Writing through the handle is writing the globals a chunk reads.
  lua.set("n", 10)
  assert_eq(or_missing(lua.eval_int("return n * 2")), 20L)
  assert_eq(lua.globals().get_str("n").as_integer(), Some(10L))
}

///|
test "reading a value with the rules the language uses" {
  let lua = Lua::new()
  // `math.tointeger`'s rule, shared with the library rather than restated: an
  // integer, a float holding one, or a string spelling either.
  assert_eq(lua.eval("return 3").unwrap().as_integer(), Some(3L))
  assert_eq(lua.eval("return 3.0").unwrap().as_integer(), Some(3L))
  assert_eq(lua.eval("return '3'").unwrap().as_integer(), Some(3L))
  assert_eq(lua.eval("return ' 3 '").unwrap().as_integer(), Some(3L))
  assert_eq(lua.eval("return 3.5").unwrap().as_integer(), None)
  assert_eq(
    lua.eval("return math.maxinteger + 1").unwrap().as_integer(),
    Some(-9223372036854775808L),
  )
  assert_eq(lua.eval("return nil").unwrap().as_integer(), None)
  assert_eq(lua.eval("return {}").unwrap().as_integer(), None)
  // A float is what `lua_tonumberx` gives, so an integer widens.
  assert_eq(lua.eval("return 3").unwrap().as_double(), Some(3.0))
  assert_eq(lua.eval("return '2e3'").unwrap().as_double(), Some(2000.0))
  assert_eq(lua.eval("return {}").unwrap().as_double(), None)
  assert_eq(lua.eval("return 'x'").unwrap().as_bytes(), Some(b"x"))
  assert_eq(lua.eval("return 1").unwrap().as_bytes(), None)
  // Identity across the boundary: the same table, read twice, is one object.
  let first = lua
    .load("local t = {} _G.shared = t return t", name="=a")
    .unwrap()
  let same = lua.call(first).unwrap()[0]
  let other = lua.eval("return _G.shared").unwrap()
  let fresh = lua.eval("return {}").unwrap()
  assert_eq(same.raw_equal(other), true)
  assert_eq(fresh.raw_equal(other), false)
  // `set` on a table the host kept is visible to the script immediately.
  match other {
    Value::VTable(t) => t.set_str("seen", Value::VInt(1L))
    _ => fail("_G.shared should be the table the chunk made")
  }
  assert_eq(or_missing(lua.eval_int("return _G.shared.seen")), 1L)
}

///|
test "a MoonBit closure as a Lua function" {
  let lua = Lua::new()
  lua.set_function("加", fn(args) {
    let mut total = 0L
    for a in args {
      total = total + a.as_integer().unwrap_or(0L)
    }
    Ok([Value::VInt(total)])
  })
  assert_eq(or_missing(lua.eval_int("return 加(1, 2, 3)")), 6L)
  // A host function is variadic and its argument count is what Lua counts.
  assert_eq(or_missing(lua.eval_int("return select('#', 加())")), 1L)
  assert_eq(or_missing(lua.eval_int("return select('#', 加(1, 2))")), 1L)
  assert_eq(lua.eval("return type(加)").unwrap().as_text(), Some("function"))

  // Several results, exactly as many as the closure answers with.
  lua.set_function("分裂", fn(args) {
    let n = args[0].as_integer().unwrap_or(0L)
    Ok([Value::VInt(n / 2L), Value::VInt(n % 2L)])
  })
  assert_eq(or_missing(lua.eval_int("return select('#', 分裂(7))")), 2L)
  // 7 / 2 = 3 and 7 % 2 = 1, the two results in the order they were answered.
  let split = lua
    .run("local a, b = 分裂(7) return a * 10 + b", name="=s")
    .unwrap()
  assert_eq(split[0].as_integer(), Some(31L))
  lua.set_function("三个", fn(_) {
    Ok([Value::VInt(1L), Value::VInt(2L), Value::VInt(3L)])
  })
  assert_eq(or_missing(lua.eval_int("return select('#', 三个())")), 3L)
  // No results at all, which is what a reference C function returning 0 does.
  lua.set_function("无声", fn(_) { Ok([]) })
  assert_eq(or_missing(lua.eval_int("return select('#', 无声())")), 0L)
  assert_eq(lua.run("return 无声()").unwrap().length(), 0)

  // An `Err` raises, so the script can catch it like any other error.
  lua.set_function("危险", fn(_) { Err(Value::text("不行")) })
  assert_eq(or_none(lua.eval_text("return select(2, pcall(危险))")), "不行")
  match lua.run("危险()", name="=raise") {
    Err(e) => assert_true(e.message.contains("不行"))
    Ok(_) => fail("the host error should escape")
  }
  // The raised value keeps its identity: a table error arrives as a table.
  lua.set_function("抛表", fn(_) {
    let t = new_table()
    t.set_str("why", Value::text("结构化"))
    Err(Value::VTable(t))
  })
  match lua.run("抛表()", name="=raise") {
    Err(e) =>
      match e.value {
        Value::VTable(t) =>
          assert_eq(t.get_str("why").as_text(), Some("结构化"))
        _ => fail("the error object should be the table the host raised")
      }
    Ok(_) => fail("the host error should escape")
  }

  // A host function is an ordinary value: a field, a method, a captured table.
  let counter = new_table()
  counter.set_str("n", Value::VInt(0L))
  counter.set_str(
    "加一",
    host_function("加一", fn(args) {
      // Called with `:`, the table arrives as the first argument.
      match args[0] {
        Value::VTable(t) => {
          let n = t.get_str("n").as_integer().unwrap_or(0L) + 1L
          t.set_str("n", Value::VInt(n))
          Ok([Value::VInt(n)])
        }
        _ => Err(Value::text("table expected"))
      }
    }),
  )
  lua.set("计数", counter)
  assert_eq(or_missing(lua.eval_int("return 计数:加一()")), 1L)
  assert_eq(or_missing(lua.eval_int("return 计数:加一()")), 2L)
  assert_eq(or_missing(lua.eval_int("return 计数.n")), 2L)
  // It works inside a coroutine, which is where a host callback is usually made.
  let in_co =
    #|local co = coroutine.create(function() return 加(4, 5) end)
    #|local ok, n = coroutine.resume(co)
    #|assert(ok and n == 9)
    #|return 计数.n
  assert_eq(or_missing(lua.eval_int(in_co)), 2L)
  // An argument the closure cannot use raises the same way the library does.
  lua.set_function("取字", fn(args) {
    match args[0].as_bytes() {
      Some(b) => Ok([Value::VInt(b.length().to_int64())])
      None => Err(Value::text("string expected"))
    }
  })
  assert_eq(
    or_none(lua.eval_text("return (select(2, pcall(取字, 1)))")),
    "string expected",
  )
}

///|
test "files load and run, with the prefix the language drops" {
  let lua = Lua::new()
  // The file is made by Lua itself, so this test needs no file API of its own.
  // The bytes and the newline come from `string.char`, because a `#|` block is a
  // MoonBit string before it is Lua: an escape here would be read twice.
  let maker =
    #|local p = os.tmpname()
    #|local f = assert(io.open(p, "wb"))
    #|f:write(string.char(239, 187, 191))            -- a UTF-8 byte order mark
    #|f:write("#!/usr/bin/lua", string.char(10))     -- the line it drops
    #|f:write("return 'from a file', ...")
    #|f:close()
    #|return p
  let path = or_none(lua.eval_text(maker))
  assert_true(path != "<missing>")
  let vs = lua.run_file(path, args=[Value::VInt(5L)]).unwrap()
  assert_eq(vs[0].as_text(), Some("from a file"))
  // A file chunk is a vararg function, and `run_file`'s arguments reach it.
  assert_eq(vs[1].as_integer(), Some(5L))

  // `load_file` compiles without running, and the chunk is named after the file.
  let f = lua.load_file(path).unwrap()
  assert_true(lua.show(f).has_prefix("function: "))
  let again = lua.call(f, args=[Value::text("z")]).unwrap()
  assert_eq(again[1].as_text(), Some("z"))
  // The chunk never ran twice by accident: a fresh load is a fresh function.
  assert_eq(f.raw_equal(lua.load_file(path).unwrap()), false)

  assert_eq(
    lua.eval_bool("return os.remove(...)", args=[Value::text(path)]).unwrap(),
    true,
  )
  // A file that is not there is an `Err`, and it says which one.
  match lua.run_file("no-such-file-here.lua") {
    Err(e) => assert_true(e.message.contains("cannot open "))
    Ok(_) => fail("a missing file should not run")
  }
  match lua.load_file("no-such-file-here.lua") {
    Err(e) => assert_true(e.message.contains("cannot open "))
    Ok(_) => fail("a missing file should not load")
  }
}

///|
test "the text of a value, and states that share nothing" {
  let lua = Lua::new()
  assert_eq(lua.show(Value::VInt(42L)), "42")
  assert_eq(lua.show(Value::text("hi")), "hi")
  assert_eq(lua.show(Value::VNil), "nil")
  assert_true(lua.show(Value::VTable(new_table())).has_prefix("table: "))
  assert_eq(lua.show(Value::VBool(true)), "true")
  let with_meta =
    #|masked = setmetatable({}, {__tostring = function() return "被改写" end})
    #|function tostring(s) return "<" .. s .. ">" end
    #|broken = setmetatable({}, {__tostring = function() error("坏") end})
  let _ = lua.run(with_meta, name="=meta")
  // `__tostring` is honoured -- that is the point of asking Lua for the text --
  // and it is the script's own `tostring`, metamethod and all.
  assert_eq(lua.show(lua.get("masked")), "被改写")
  assert_eq(or_none(lua.eval_text("return tostring('x')")), "<x>")
  // A metamethod that fails does not raise out of `show`: the reference's own
  // wording for "there is no text for this" comes back instead.
  assert_eq(lua.show(lua.get("broken")), "(error object is a table value)")

  let other = Lua::new()
  assert_eq(other.get("masked").is_nil(), true)
  other.set("only_there", 1)
  assert_eq(lua.get("only_there").is_nil(), true)
  // `-E` is available, and the defaults are still there.
  let quiet = Lua::new(ignore_env=true)
  assert_eq(
    quiet.eval_bool("return type(package.path) == 'string'").unwrap(),
    true,
  )
  assert_eq(
    quiet.eval_bool("return type(package.searchers) == 'table'").unwrap(),
    true,
  )
}

///|
/// The example in README.md's "作为库使用" section, kept honest: the same code,
/// run as a test.
test "the README's example" {
  let lua = Lua::new()
  lua.set("上限", 100)
  lua.set_function("平方", fn(args) {
    match args[0].as_integer() {
      Some(x) => Ok([Value::VInt(x * x)])
      None => Err(Value::text("integer expected"))
    }
  })
  assert_eq(or_missing(lua.eval_int("return 平方(3) + 上限")), 109L)
}

///|
/// The typed reads, on the values a script actually produces: a result list, a
/// table's own fields, a sequence with a hole in it.
test "reading a result list and a table's shape" {
  let lua = Lua::new()
  let vs = lua.run("return 'a', 'b', 'c'").unwrap()
  let texts : Result[Array[String], LuaError] = lua.values_as(vs)
  assert_eq(texts.unwrap(), ["a", "b", "c"])
  // One value of the wrong kind fails the whole list, and names that value.
  let mixed : Result[Array[String], LuaError] = lua.values_as(
    lua.run("return 'a', 2").unwrap(),
  )
  assert_true(mixed is Err(_))
  assert_eq(mixed.unwrap_err().message, "string expected, got number")

  // `get_as` is `get` with the conversion's error attached.
  lua.set("配置", Map([("宽", 800), ("高", 600)]))
  let size : Result[Map[String, Int], LuaError] = lua.get_as("配置")
  assert_eq(size.unwrap(), Map([("宽", 800), ("高", 600)]))
  let absent : Result[Map[String, Int], LuaError] = lua.get_as("没有")
  assert_eq(absent.unwrap_err().message, "table expected, got nil")

  // A table's own fields, in `next`'s order: two array-part slots and one key.
  let first : Table? = read_lua(lua.eval("return {10, 20, x = 'y'}").unwrap())
  let entries = table_entries(first.unwrap())
  assert_eq(entries.length(), 3)
  let kinds = entries.map(e => e.0.type_name())
  kinds.sort()
  assert_eq(kinds, ["number", "number", "string"])
  // The sequence reading stops at the first absent field, so a hole ends it.
  let hole : Table? = read_lua(lua.eval("return {1, nil, 3}").unwrap())
  let head = table_sequence(hole.unwrap())
  assert_eq(head.length(), 1)
  assert_eq(head[0].as_integer(), Some(1L))
  let packed : Table? = read_lua(lua.eval("return {7, 8}").unwrap())
  assert_eq(table_sequence(packed.unwrap()).length(), 2)
}

///|
/// A host module a script can `require`: `preload` installs the loader Lua's
/// searchers find, `require` runs it once and caches what it answered.
test "a module a script can require" {
  let lua = Lua::new()
  let runs = Ref(0)
  lua.preload("模块", fn(args) {
    let _ = args
    runs.val = runs.val + 1
    let t = new_table()
    t.set_str("值", Value::VInt(7L))
    Ok([t.as_value()])
  })
  assert_eq(or_missing(lua.eval_int("return require('模块').值")), 7L)
  assert_eq(or_missing(lua.eval_int("return require('模块').值")), 7L)
  // The loader ran once: the second `require` got `package.loaded`'s answer.
  assert_eq(runs.val, 1)
  // The host's own `require` sees the table the script got.
  let m = lua.require("模块").unwrap()
  assert_eq(m.type_name(), "table")
  assert_true(m.raw_equal(lua.eval("return package.loaded['模块']").unwrap()))
  // A name nothing can load fails the way `require` does in Lua.
  let missing = lua.require("没有这个模块")
  assert_true(missing is Err(_))
  assert_true(
    missing.unwrap_err().message.contains(
      "module '没有这个模块' not found",
    ),
  )
  // A loader that answers with nothing gets the reference's dummy `true`, which
  // is what `require` hands back and caches.
  lua.preload("空", fn(args) {
    let _ = args
    Ok([])
  })
  assert_eq(lua.require("空").unwrap().type_name(), "boolean")
}
