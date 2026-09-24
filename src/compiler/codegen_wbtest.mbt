// The shape of the generated code, where a register is part of the semantics:
// a call leaves its results over the slot that held the function, so where the
// callee sits decides how many slots a frame shows as `(temporary)`, and only
// `return f(x)` becomes a tail call.

///|
fn listing(src : Bytes) -> String raise {
  let body = parse_chunk(src, "probe")
  let proto = compile_chunk(body, @core.LStr::of_string("=probe"))
  let inner = proto.protos[0]
  let parts : Array[String] = []
  for i in 0..<inner.code.length() {
    let c = inner.code[i]
    let line = @core.line_at(inner, i)
    let text = "\{i} \{@core.op_name(c.op)} \{c.a} \{c.b} \{c.c} line=\{line}"
    parts.push(text)
  }
  parts.join("\n")
}

///|
test "register placement and tail calls" {
  inspect(
    listing(b"function g(a,b) return (a+1) + f() end"),
    content=(
      #|0 MOVE 2 0 0 line=1
      #|1 ADD 2 2 256 line=1
      #|2 GETTABUP 3 0 257 line=1
      #|3 CALL 3 1 2 line=1
      #|4 ADD 2 2 3 line=1
      #|5 RETURN 2 2 0 line=1
      #|6 RETURN 2 1 0 line=1
    ),
  )
  inspect(
    listing(b"function g(x) return f(x) end"),
    content=(
      #|0 GETTABUP 1 0 256 line=1
      #|1 MOVE 2 0 0 line=1
      #|2 TAILCALL 1 2 0 line=1
      #|3 RETURN 1 0 0 line=1
      #|4 RETURN 1 1 0 line=1
    ),
  )
  inspect(
    listing(b"function g(x) return f(x) + 1 end"),
    content=(
      #|0 GETTABUP 1 0 256 line=1
      #|1 MOVE 2 0 0 line=1
      #|2 CALL 1 2 2 line=1
      #|3 ADD 1 1 257 line=1
      #|4 RETURN 1 2 0 line=1
      #|5 RETURN 1 1 0 line=1
    ),
  )
  // A call whose values are returned is not a tail call while the frame still
  // owes a `__close`: the reference keeps the call where it is.
  inspect(
    listing(b"function g(x) local _ <close> = c return f(x) end"),
    content=(
      #|0 GETTABUP 1 0 256 line=1
      #|1 TBC 1 0 0 line=1
      #|2 GETTABUP 2 0 257 line=1
      #|3 MOVE 3 0 0 line=1
      #|4 CALL 2 2 0 line=1
      #|5 RETURN 2 0 0 line=1
      #|6 RETURN 2 1 0 line=1
      #|7 CLOSE 0 0 0 line=1
    ),
  )
}
