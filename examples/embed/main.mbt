// Embedding the interpreter in a MoonBit program:
//
//   moon run examples/embed
//
// Everything here goes through the public interface of `hongweifei/lua`: one
// import, no `Bytes`, no C-shaped callback.  Each section asserts its own
// result, so running the program is the test.
//
// The Chinese names below are this implementation's own extension -- a well
// formed non-ASCII code point is a name character, where the reference's
// `lislalpha` knows only ASCII.  The last section shows the portable spelling.

///|
fn main raise {
  let lua = @lua.Lua::new()

  // A chunk's results come back as Lua values, read by the rules the language
  // uses: `as_integer` is `math.tointeger`'s, `as_double` a number's.
  let vs = lua.run("return 6 * 7, 'aloha', true, nil", name="=embed").unwrap()
  assert_eq(vs[0].as_integer(), Some(42L))
  assert_eq(vs[1].as_text(), Some("aloha"))
  assert_eq(vs[2].is_truthy(), true)
  assert_eq(vs[3].is_nil(), true)
  println("a chunk answered with \{vs.length()} values")

  // MoonBit data goes the other way as globals: scalars, a sequence numbered
  // from 1, a map, and `None`, which is `nil` to a script.
  lua.set("greeting", "你好")
  lua.set("limit", 3)
  lua.set("ratio", 2.5)
  lua.set("items", [10, 20, 30])
  let config : Map[String, Int] = Map::from_array([("width", 80)])
  lua.set("config", config)
  lua.set("nothing", (None : Int?))
  let shaped =
    #|local out = {}
    #|out[#out + 1] = string.format("%s %d %.3f", greeting, limit, ratio)
    #|out[#out + 1] = table.concat(items, ",") .. " " .. config.width
    #|out[#out + 1] = type(nothing)
    #|return table.concat(out, " | ")
  let lines = lua.run(shaped, name="=embed").unwrap()
  assert_eq(lines[0].as_text(), Some("你好 3 2.500 | 10,20,30 80 | nil"))
  println(lines[0].as_text().unwrap_or(""))

  // A MoonBit closure *is* a Lua function: variadic, multi-result, and its
  // `Err` arrives as an ordinary Lua error, catchable by the script.
  lua.set_function("面积", fn(args) {
    let wide = args[0].as_double().unwrap_or(0.0)
    let high = args[1].as_double().unwrap_or(0.0)
    Ok([@lua.Value::VNum(wide * high)])
  })
  lua.set_function("减半", fn(args) {
    match args[0].as_integer() {
      Some(n) =>
        if n >= 0L {
          Ok([@lua.Value::VInt(n / 2L)])
        } else {
          Err(@lua.Value::text("a non-negative integer is needed"))
        }
      None => Err(@lua.Value::text("an integer is needed"))
    }
  })
  let calling =
    #|local a = 面积(3, 2.5)
    #|local ok, why = pcall(减半, -4)
    #|return a, ok, why, select('#', 面积(2, 2))
  let areas = lua.run(calling, name="=embed").unwrap()
  assert_eq(areas[0].as_double(), Some(7.5))
  assert_eq(areas[1].is_truthy(), false)
  assert_true(areas[2].as_text().unwrap_or("").contains("non-negative"))
  // One value answered, so one value counted.
  assert_eq(areas[3].as_integer(), Some(1L))
  println("a host closure computed \{areas[0].as_double().unwrap_or(0.0)}")

  // A function the script defined is callable with MoonBit arguments, and a
  // structured error keeps its shape rather than collapsing into a message.
  let defined =
    #|function add(a, b) return a + b, 'two results too' end
    #|function fail() error({ code = 42, msg = '结构化' }) end
    #|masked = setmetatable({}, {__tostring = function() return '被改写' end})
  let _ = lua.run(defined, name="=embed")
  let sum = lua
    .call_global("add", args=[@lua.Value::VInt(20L), @lua.Value::VInt(22L)])
    .unwrap()
  assert_eq(sum[0].as_integer(), Some(42L))
  assert_eq(sum[1].as_text(), Some("two results too"))
  match lua.run("fail()", name="=embed") {
    Err(err) => {
      assert_eq(err.message, "(error object is a table value)")
      match err.value {
        @lua.Value::VTable(t) => {
          assert_eq(t.get_str("code").as_integer(), Some(42L))
          assert_eq(t.get_str("msg").as_text(), Some("结构化"))
        }
        _ => fail("the raised table should survive the boundary")
      }
    }
    Ok(_) => fail("the script was expected to fail")
  }
  // `show` is the text Lua itself would print, metamethod included.
  assert_eq(lua.show(lua.get("masked")), "被改写")
  println("a script's function returned \{sum[0].as_integer().unwrap_or(0L)}")

  // The portable spelling: ASCII names, bytes exact, and a second state that
  // shares nothing with the first.
  lua.set_function("slug", fn(args) {
    let raw = args[0].as_bytes().unwrap_or(b"")
    Ok([@lua.Value::VInt(raw.length().to_int64())])
  })
  assert_eq(lua.eval_int("return slug('hello')").unwrap_or(-1L), 5L)
  // Bytes that are not UTF-8 survive a round trip, which is why the reader is
  // `as_bytes` and not only text.
  assert_eq(lua.eval_bytes("return string.char(255)").unwrap(), b"\xff")
  let other = @lua.Lua::new()
  assert_true(other.get("greeting").is_nil())
  assert_eq(lua.get("limit").as_integer(), Some(3L))
  println("two states, two worlds; a host function counted 5 bytes")
}
