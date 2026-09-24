// Entry points of the code generator.

///|
pub fn line_of(e : Expr) -> Int {
  match e {
    ENil(l) => l
    ETrue(l) => l
    EFalse(l) => l
    EInt(_, l) => l
    EFloat(_, l) => l
    EString(_, l) => l
    EVararg(l) => l
    EName(_, l) => l
    EIndex(_, _, l) => l
    ECall(_, _, l) => l
    EMethod(_, _, _, l) => l
    EBinary(_, _, _, l) => l
    EUnary(_, _, l) => l
    ETable(_, l) => l
    EParen(_, l) => l
    EFunction(fb) => fb.line_defined
  }
}

///|
/// The line of the last token of an expression.  The reference emits whatever
/// follows an expression at the line its last token was read on, so the code
/// generator needs this to place the store of an assignment, whose right hand
/// side may run over several lines.
pub fn end_line_of(e : Expr) -> Int {
  match e {
    // The closing bracket follows the key or the last argument.
    EIndex(_, key, _) => end_line_of(key)
    ECall(_, args, l) => last_end_line(args, l)
    EMethod(_, _, args, l) => last_end_line(args, l)
    ETable(fields, l) =>
      if fields.length() == 0 {
        l
      } else {
        match fields[fields.length() - 1] {
          FPositional(v) => end_line_of(v)
          FKeyed(_, v) => end_line_of(v)
        }
      }
    EBinary(_, _, r, _) => end_line_of(r)
    EUnary(_, operand, _) => end_line_of(operand)
    EParen(inner, _) => end_line_of(inner)
    EFunction(body) => body.last_line
    _ => line_of(e)
  }
}

///|
fn last_end_line(args : Array[Expr], fallback : Int) -> Int {
  if args.length() == 0 {
    fallback
  } else {
    end_line_of(args[args.length() - 1])
  }
}

///|
/// Compiles a parsed chunk, producing the prototype of the main function.
pub fn compile_chunk(
  body : FuncBody,
  source : @core.LStr,
) -> @core.LProto raise @core.LuaRaised {
  let main = FuncState::new(None, source, body.name, 0, 0, true)
  // The main function receives the global table as its `_ENV` upvalue.
  let _ = main.new_upvalue(@core.LStr::of_string("_ENV"), false, 0)
  compile_function_body(main, body)
  main.finalize()
}

///|
/// Compiles the body of one function and places the resulting closure in `reg`.
pub fn compile_closure(
  fs : FuncState,
  body : FuncBody,
  reg : Int,
) -> Unit raise @core.LuaRaised {
  let inner = FuncState::new(
    Some(fs),
    fs.source,
    body.name,
    body.line_defined,
    body.params.length(),
    body.is_vararg,
  )
  inner.line = body.line_defined
  inner.last_line_defined = body.last_line
  for p in body.params {
    inner.register_local(p)
  }
  compile_function_body(inner, body)
  let proto = inner.finalize()
  let idx = fs.protos.length()
  fs.protos.push(proto)
  // The closure is built once the whole body has been read, which is where the
  // reference's single-pass parser is too.
  fs.line = body.last_line
  let _ = fs.emit_ab(@core.OP_CLOSURE, reg, idx)
  // The instructions that follow describe how to bind each upvalue: either a
  // register of the enclosing frame, or one of its own upvalues.
  for d in proto.upvals {
    if d.in_stack {
      let _ = fs.emit(@core.instr(@core.OP_MOVE, 0, d.index, 0))
    } else {
      let _ = fs.emit(@core.instr(@core.OP_GETUPVAL, 0, d.index, 0))
    }
  }
}

///|
/// Compiles the statements of a function and appends the implicit trailing
/// return.
pub fn compile_function_body(
  fs : FuncState,
  body : FuncBody,
) -> Unit raise @core.LuaRaised {
  compile_stat_list(fs, body.body, true)
  fs.line = body.last_line
  let _ = fs.emit_ab(@core.OP_RETURN, fs.nactive, 1)
  fs.leave_block()
}
