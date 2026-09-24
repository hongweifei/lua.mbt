// Conversion of numerals and the rendering of numbers, the two places where a
// silent rounding or parsing slip would corrupt program behaviour.

///|
let inf : Double = 1.0e300 * 1.0e300

///|
let nan : Double = 0.0 / 0.0

///|
/// How `lua_str2num` reads one numeral, as text a snapshot can compare.
fn numeral(s : String) -> String {
  match lua_str2num(bytes_of(s)) {
    None => "nil"
    Some(NInt(i)) => "int " + int64_to_bytes(i).to_string()
    Some(NFloat(d)) => "float " + double_to_g14(d).to_string()
  }
}

///|
test "numerals convert as the language specifies" {
  let cases = [
    "1", "  10  ", "+3", "-3", "1e1", "1.5", "3.0", ".5", "5.", "1e", "0x10", "0X1P4",
    "0x.8p-1", "0x10.8", "0x1p-1074", "0x1p1024", "0x7fffffffffffffff", "0xffffffffffffffff",
    "9223372036854775807", "9223372036854775808", "1e999", "1e-999", "abc", "", " ",
    "1 2", "0x", "1.0e14",
  ]
  debug_inspect(
    [
      for c in cases => c + " => " + numeral(c)
    ],
    content=(
      #|[
      #|  "1 => int b\"1\"",
      #|  "  10   => int b\"10\"",
      #|  "+3 => int b\"3\"",
      #|  "-3 => int b\"-3\"",
      #|  "1e1 => float b\"10.0\"",
      #|  "1.5 => float b\"1.5\"",
      #|  "3.0 => float b\"3.0\"",
      #|  ".5 => float b\"0.5\"",
      #|  "5. => float b\"5.0\"",
      #|  "1e => nil",
      #|  "0x10 => int b\"16\"",
      #|  "0X1P4 => float b\"16.0\"",
      #|  "0x.8p-1 => float b\"0.25\"",
      #|  "0x10.8 => float b\"16.5\"",
      #|  "0x1p-1074 => float b\"4.9406564584125e-324\"",
      #|  "0x1p1024 => float b\"inf\"",
      #|  "0x7fffffffffffffff => int b\"9223372036854775807\"",
      #|  "0xffffffffffffffff => int b\"-1\"",
      #|  "9223372036854775807 => int b\"9223372036854775807\"",
      #|  "9223372036854775808 => float b\"9.2233720368548e+18\"",
      #|  "1e999 => float b\"inf\"",
      #|  "1e-999 => float b\"0.0\"",
      #|  "abc => nil",
      #|  " => nil",
      #|  "  => nil",
      #|  "1 2 => nil",
      #|  "0x => nil",
      #|  "1.0e14 => float b\"1e+14\"",
      #|]
    ),
  )
}

///|
fn show_number(v : Value) -> String {
  number_to_bytes(v).to_string()
}

///|
test "numbers render like the reference" {
  debug_inspect(
    [
      show_number(VInt(0L)),
      show_number(VInt(-1L)),
      show_number(VInt(9223372036854775807L)),
      show_number(VNum(1.0)),
      show_number(VNum(-0.0)),
      show_number(VNum(0.5)),
      show_number(VNum(1.0 / 3.0)),
      show_number(VNum(1.0e14)),
      show_number(VNum(1.0e15)),
      show_number(VNum(1.0e16)),
      show_number(VNum(1234567890123456.0)),
      show_number(VNum(1.0e-4)),
      show_number(VNum(1.0e-5)),
      show_number(VNum(1.0e22)),
      show_number(VNum(1.0e23)),
      show_number(VNum(inf)),
      show_number(VNum(-inf)),
      show_number(VNum(nan)),
      show_number(VNum(9007199254740993.0)),
    ],
    content=(
      #|[
      #|  "b\"0\"",
      #|  "b\"-1\"",
      #|  "b\"9223372036854775807\"",
      #|  "b\"1.0\"",
      #|  "b\"-0.0\"",
      #|  "b\"0.5\"",
      #|  "b\"0.33333333333333\"",
      #|  "b\"1e+14\"",
      #|  "b\"1e+15\"",
      #|  "b\"1e+16\"",
      #|  "b\"1.2345678901235e+15\"",
      #|  "b\"0.0001\"",
      #|  "b\"1e-05\"",
      #|  "b\"1e+22\"",
      #|  "b\"1e+23\"",
      #|  "b\"inf\"",
      #|  "b\"-inf\"",
      #|  "b\"nan\"",
      #|  "b\"9.007199254741e+15\"",
      #|]
    ),
  )
}

///|

///|
/// Integers and floats compare exactly, even where a double cannot hold the
/// integer.
fn cmp_case(i : Int64, d : Double) -> String {
  let up = int64_to_bytes(i).to_string() + " "
  let forward = if int_lt_float(i, d) {
    "<"
  } else if int_equals_float(i, d) {
    "="
  } else {
    ">"
  }
  let back = if float_lt_int(d, i) {
    "<"
  } else if int_equals_float(i, d) {
    "="
  } else {
    ">"
  }
  up +
  forward +
  " " +
  double_to_g14(d).to_string() +
  " / " +
  back +
  " int<=" +
  (if int_le_float(i, d) { "t" } else { "f" }) +
  " float<=" +
  (if float_le_int(d, i) { "t" } else { "f" })
}

///|
test "mixed comparisons stay exact" {
  debug_inspect(
    [
      cmp_case(9007199254740993L, 9007199254740992.0),
      cmp_case(9007199254740992L, 9007199254740992.0),
      cmp_case(9223372036854775807L, 9223372036854775808.0),
      cmp_case(-9223372036854775808L, -9223372036854775809.0),
      cmp_case(0L, 0.0),
      cmp_case(0L, -0.0),
      cmp_case(1L, 0.5),
      cmp_case(1L, 1.5),
    ],
    content=(
      #|[
      #|  "b\"9007199254740993\" > b\"9.007199254741e+15\" / < int<=f float<=t",
      #|  "b\"9007199254740992\" = b\"9.007199254741e+15\" / = int<=t float<=t",
      #|  "b\"9223372036854775807\" < b\"9.2233720368548e+18\" / > int<=t float<=f",
      #|  "b\"-9223372036854775808\" = b\"-9.2233720368548e+18\" / = int<=t float<=t",
      #|  "b\"0\" = b\"0.0\" / = int<=t float<=t",
      #|  "b\"0\" = b\"-0.0\" / = int<=t float<=t",
      #|  "b\"1\" > b\"0.5\" / < int<=f float<=t",
      #|  "b\"1\" < b\"1.5\" / > int<=t float<=f",
      #|]
    ),
  )
}

///|
test "the remainder follows the sign of the divisor" {
  debug_inspect(
    [
      double_to_g14(float_mod(7.0, 3.0)).to_string(),
      double_to_g14(float_mod(-7.0, 3.0)).to_string(),
      double_to_g14(float_mod(7.0, -3.0)).to_string(),
      double_to_g14(float_mod(-7.0, -3.0)).to_string(),
      double_to_g14(float_mod(7.0, 0.0)).to_string(),
      double_to_g14(float_mod(0.0, -3.0)).to_string(),
    ],
    content=(
      #|[
      #|  "b\"1.0\"",
      #|  "b\"2.0\"",
      #|  "b\"-2.0\"",
      #|  "b\"-1.0\"",
      #|  "b\"nan\"",
      #|  "b\"0.0\"",
      #|]
    ),
  )
}

///|
/// One conversion per call, because the host formatter is `snprintf` and a
/// mismatched number of arguments would read past the value.
fn fmt_d(d : Double, spec : String) -> String {
  text_of(format_with_double(d, bytes_of(spec)))
}

///|
fn fmt_i(i : Int64, spec : String) -> String {
  text_of(format_with_int64(i, bytes_of(spec)))
}

///|
test "printf conversions" {
  debug_inspect(
    [
      fmt_d(1.0 / 3.0, "%.17g"),
      fmt_d(0.1, "%e"),
      fmt_d(1234.5678, "%6.2f"),
      fmt_d(inf, "%.14g"),
      fmt_d(-0.0, "%g"),
      fmt_d(1.0e100, "%9.3e"),
      fmt_i(-1L, "%d"),
      fmt_i(255L, "%x"),
      fmt_i(255L, "%X"),
      fmt_i(255L, "%o"),
      fmt_i(65L, "%c"),
      fmt_i(7L, "%5.2d"),
      fmt_i(-7L, "%08d"),
      text_of(format_with_uint64(0xffff_ffff_ffff_ffffUL, bytes_of("%llx"))),
    ],
    content=(
      #|[
      #|  "0.33333333333333331",
      #|  "1.000000e-01",
      #|  "1234.57",
      #|  "inf",
      #|  "-0",
      #|  "1.000e+100",
      #|  "-1",
      #|  "ff",
      #|  "FF",
      #|  "377",
      #|  "A",
      #|  "   07",
      #|  "-0000007",
      #|  "ffffffffffffffff",
      #|]
    ),
  )
}
