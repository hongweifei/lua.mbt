// Token kinds and the reserved words.

///|
pub const TK_EOF : Int = 0

///|
pub const TK_NAME : Int = 1

///|
pub const TK_INT : Int = 2

///|
pub const TK_FLOAT : Int = 3

///|
pub const TK_STRING : Int = 4

///|
pub const TK_AND : Int = 10

///|
pub const TK_BREAK : Int = 11

///|
pub const TK_DO : Int = 12

///|
pub const TK_ELSE : Int = 13

///|
pub const TK_ELSEIF : Int = 14

///|
pub const TK_END : Int = 15

///|
pub const TK_FALSE : Int = 16

///|
pub const TK_FOR : Int = 17

///|
pub const TK_FUNCTION : Int = 18

///|
pub const TK_GOTO : Int = 19

///|
pub const TK_IF : Int = 20

///|
pub const TK_IN : Int = 21

///|
pub const TK_LOCAL : Int = 22

///|
pub const TK_NIL : Int = 23

///|
pub const TK_NOT : Int = 24

///|
pub const TK_OR : Int = 25

///|
pub const TK_REPEAT : Int = 26

///|
pub const TK_RETURN : Int = 27

///|
pub const TK_THEN : Int = 28

///|
pub const TK_TRUE : Int = 29

///|
pub const TK_UNTIL : Int = 30

///|
pub const TK_WHILE : Int = 31

///|
pub const TK_PLUS : Int = 40

///|
pub const TK_MINUS : Int = 41

///|
pub const TK_STAR : Int = 42

///|
pub const TK_SLASH : Int = 43

///|
pub const TK_DSLASH : Int = 44

///|
pub const TK_PERCENT : Int = 45

///|
pub const TK_CARET : Int = 46

///|
pub const TK_HASH : Int = 47

///|
pub const TK_AMP : Int = 48

///|
pub const TK_TILDE : Int = 49

///|
pub const TK_PIPE : Int = 50

///|
pub const TK_SHL : Int = 51

///|
pub const TK_SHR : Int = 52

///|
pub const TK_EQ : Int = 53

///|
pub const TK_NE : Int = 54

///|
pub const TK_LE : Int = 55

///|
pub const TK_GE : Int = 56

///|
pub const TK_LT : Int = 57

///|
pub const TK_GT : Int = 58

///|
pub const TK_ASSIGN : Int = 59

///|
pub const TK_LPAREN : Int = 60

///|
pub const TK_RPAREN : Int = 61

///|
pub const TK_LBRACE : Int = 62

///|
pub const TK_RBRACE : Int = 63

///|
pub const TK_LBRACKET : Int = 64

///|
pub const TK_RBRACKET : Int = 65

///|
pub const TK_DCOLON : Int = 66

///|
pub const TK_SEMI : Int = 67

///|
pub const TK_COLON : Int = 68

///|
pub const TK_COMMA : Int = 69

///|
pub const TK_DOT : Int = 70

///|
pub const TK_CONCAT : Int = 71

///|
pub const TK_ELLIPSIS : Int = 72

///|
/// A lexical token.  `text` holds the identifier or the string contents; the
/// numeric fields are only meaningful for `TK_INT` and `TK_FLOAT`.
pub(all) struct Token {
  kind : Int
  text : @core.LStr
  /// The token exactly as it was written, which is how the reference
  /// implementation quotes it in syntax errors.
  raw : Bytes
  int_value : Int64
  float_value : Double
  line : Int
}

///|
/// Human readable name of a token kind, as used inside diagnostics.
pub fn token_name(kind : Int) -> String {
  match kind {
    TK_EOF => "<eof>"
    TK_NAME => "name"
    TK_INT => "int"
    TK_FLOAT => "float"
    TK_STRING => "string"
    TK_AND => "and"
    TK_BREAK => "break"
    TK_DO => "do"
    TK_ELSE => "else"
    TK_ELSEIF => "elseif"
    TK_END => "end"
    TK_FALSE => "false"
    TK_FOR => "for"
    TK_FUNCTION => "function"
    TK_GOTO => "goto"
    TK_IF => "if"
    TK_IN => "in"
    TK_LOCAL => "local"
    TK_NIL => "nil"
    TK_NOT => "not"
    TK_OR => "or"
    TK_REPEAT => "repeat"
    TK_RETURN => "return"
    TK_THEN => "then"
    TK_TRUE => "true"
    TK_UNTIL => "until"
    TK_WHILE => "while"
    TK_PLUS => "+"
    TK_MINUS => "-"
    TK_STAR => "*"
    TK_SLASH => "/"
    TK_DSLASH => "//"
    TK_PERCENT => "%"
    TK_CARET => "^"
    TK_HASH => "#"
    TK_AMP => "&"
    TK_TILDE => "~"
    TK_PIPE => "|"
    TK_SHL => "<<"
    TK_SHR => ">>"
    TK_EQ => "=="
    TK_NE => "~="
    TK_LE => "<="
    TK_GE => ">="
    TK_LT => "<"
    TK_GT => ">"
    TK_ASSIGN => "="
    TK_LPAREN => "("
    TK_RPAREN => ")"
    TK_LBRACE => "{"
    TK_RBRACE => "}"
    TK_LBRACKET => "["
    TK_RBRACKET => "]"
    TK_DCOLON => "::"
    TK_SEMI => ";"
    TK_COLON => ":"
    TK_COMMA => ","
    TK_DOT => "."
    TK_CONCAT => ".."
    TK_ELLIPSIS => "..."
    _ => "?"
  }
}

///|
/// The reserved words, in the order the language defines them.
pub let keywords : Array[(String, Int)] = [
  ("and", TK_AND),
  ("break", TK_BREAK),
  ("do", TK_DO),
  ("else", TK_ELSE),
  ("elseif", TK_ELSEIF),
  ("end", TK_END),
  ("false", TK_FALSE),
  ("for", TK_FOR),
  ("function", TK_FUNCTION),
  ("goto", TK_GOTO),
  ("if", TK_IF),
  ("in", TK_IN),
  ("local", TK_LOCAL),
  ("nil", TK_NIL),
  ("not", TK_NOT),
  ("or", TK_OR),
  ("repeat", TK_REPEAT),
  ("return", TK_RETURN),
  ("then", TK_THEN),
  ("true", TK_TRUE),
  ("until", TK_UNTIL),
  ("while", TK_WHILE),
]

///|
pub fn keyword_kind(text : Bytes) -> Int {
  for pair in keywords {
    if @core.bytes_of(pair.0) == text {
      return pair.1
    }
  }
  TK_NAME
}
