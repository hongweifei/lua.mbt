// Operator codes shared by the front end and the virtual machine.

///|
pub const BINOP_ADD : Int = 0

///|
pub const BINOP_SUB : Int = 1

///|
pub const BINOP_MUL : Int = 2

///|
pub const BINOP_DIV : Int = 3

///|
pub const BINOP_MOD : Int = 4

///|
pub const BINOP_POW : Int = 5

///|
pub const BINOP_IDIV : Int = 6

///|
pub const BINOP_BAND : Int = 7

///|
pub const BINOP_BOR : Int = 8

///|
pub const BINOP_BXOR : Int = 9

///|
pub const BINOP_SHL : Int = 10

///|
pub const BINOP_SHR : Int = 11

///|
pub const BINOP_CONCAT : Int = 12

///|
pub const BINOP_EQ : Int = 13

///|
pub const BINOP_LT : Int = 14

///|
pub const BINOP_LE : Int = 15

///|
pub const BINOP_NE : Int = 16

///|
pub const BINOP_GT : Int = 17

///|
pub const BINOP_GE : Int = 18

///|
pub const BINOP_AND : Int = 19

///|
pub const BINOP_OR : Int = 20

///|
pub const UNOP_MINUS : Int = 0

///|
pub const UNOP_NOT : Int = 1

///|
pub const UNOP_LEN : Int = 2

///|
pub const UNOP_BNOT : Int = 3

///|
/// The textual form of a binary operator, for diagnostics.
pub fn binop_text(op : Int) -> String {
  match op {
    BINOP_ADD => "+"
    BINOP_SUB => "-"
    BINOP_MUL => "*"
    BINOP_DIV => "/"
    BINOP_MOD => "%"
    BINOP_POW => "^"
    BINOP_IDIV => "//"
    BINOP_BAND => "&"
    BINOP_BOR => "|"
    BINOP_BXOR => "~"
    BINOP_SHL => "<<"
    BINOP_SHR => ">>"
    BINOP_CONCAT => ".."
    BINOP_EQ => "=="
    BINOP_LT => "<"
    BINOP_LE => "<="
    BINOP_NE => "~="
    BINOP_GT => ">"
    BINOP_GE => ">="
    BINOP_AND => "and"
    BINOP_OR => "or"
    _ => "?"
  }
}

///|
/// The metamethod that implements an arithmetic or comparison operator.
pub fn binop_metamethod(op : Int) -> String {
  match op {
    BINOP_ADD => "__add"
    BINOP_SUB => "__sub"
    BINOP_MUL => "__mul"
    BINOP_DIV => "__div"
    BINOP_MOD => "__mod"
    BINOP_POW => "__pow"
    BINOP_IDIV => "__idiv"
    BINOP_BAND => "__band"
    BINOP_BOR => "__bor"
    BINOP_BXOR => "__bxor"
    BINOP_SHL => "__shl"
    BINOP_SHR => "__shr"
    BINOP_CONCAT => "__concat"
    BINOP_EQ => "__eq"
    BINOP_LT => "__lt"
    BINOP_LE => "__le"
    _ => "?"
  }
}
