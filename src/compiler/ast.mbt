// The abstract syntax tree.

///|
pub const ATTRIB_NONE : Int = 0

///|
pub const ATTRIB_CONST : Int = 1

///|
pub const ATTRIB_CLOSE : Int = 2

///|
/// One name in a `local` declaration.
pub(all) struct LocalDecl {
  name : @core.LStr
  attrib : Int
  line : Int
}

///|
/// A field of a table constructor.
pub(all) enum Field {
  /// `{ e }`
  FPositional(Expr)
  /// `{ name = e }` and `{ [k] = e }` both land here once the key is built.
  FKeyed(Expr, Expr)
}

///|
/// An expression.
pub(all) enum Expr {
  ENil(Int)
  ETrue(Int)
  EFalse(Int)
  EInt(Int64, Int)
  EFloat(Double, Int)
  EString(@core.LStr, Int)
  EVararg(Int)
  EFunction(FuncBody)
  /// A plain name; whether it denotes a local, an upvalue or a global is decided
  /// by the compiler, which is the only place that knows the scopes.
  EName(@core.LStr, Int)
  /// `a[b]`
  EIndex(Expr, Expr, Int)
  /// `f(args)`; the integer is the line of the call.
  ECall(Expr, Array[Expr], Int)
  /// `o:m(args)`
  EMethod(Expr, @core.LStr, Array[Expr], Int)
  EBinary(Int, Expr, Expr, Int)
  EUnary(Int, Expr, Int)
  ETable(Array[Field], Int)
  /// `(e)`, which yields exactly one value.
  EParen(Expr, Int)
}

///|
/// A statement.
pub(all) enum Stat {
  /// `local a, b = 1, 2`
  SLocal(Array[LocalDecl], Array[Expr], Int)
  /// `a, b = 1, 2`
  SAssign(Array[Expr], Array[Expr], Int)
  /// `f()`
  SCall(Expr)
  /// `do ... end`
  SDo(Block)
  SWhile(Expr, Block, Int)
  SRepeat(Block, Expr, Int)
  /// `if ... then ... end`, with the `elseif` clauses and the optional `else`.
  /// A clause also carries the line of its `then`, which is where the test that
  /// skips the body belongs.
  SIf(Array[(Expr, Block, Int)], Block?, Int)
  /// `for i = e, e, e do ... end`: the `for` line, where the loop test belongs,
  /// and the `do` line, where the setup does.
  SNumericFor(@core.LStr, Expr, Expr, Expr?, Block, Int, Int)
  /// `for names in exprs do ... end`: the `for` line, the line of the first
  /// iterator expression, which owns the implicit call, and the `do` line.
  SGenericFor(Array[@core.LStr], Array[Expr], Block, Int, Int, Int)
  /// `function name.a.b(...) ... end` and `function name:m() ... end`
  SFunction(Expr, FuncBody, Int)
  SLocalFunction(@core.LStr, FuncBody, Int)
  SReturn(Array[Expr], Int)
  SBreak(Int)
  SGoto(@core.LStr, Int)
  SLabel(@core.LStr, Int)
}

///|
/// A sequence of statements.  Each block introduces a scope.
pub(all) struct Block {
  stats : Array[Stat]
  /// The line of the last token the block consumed, which is where the
  /// reference stamps the jumps emitted just after a block: the back edge of a
  /// loop, or the jump over an `else`.
  exit_line : Int
}

///|
/// The body of a function.
pub(all) struct FuncBody {
  params : Array[@core.LStr]
  is_vararg : Bool
  body : Block
  line_defined : Int
  last_line : Int
  /// A human readable name used in error messages, e.g. `function 'f'`.
  name : String
}

///|----------------------------------------------------------------
/// Operator codes for `EBinary` and `EUnary`.  The order is the one used by the
/// code generator's dispatch tables.
