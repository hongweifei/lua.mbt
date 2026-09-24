// Pattern searching, matching, iteration and substitution.

///|
pub fn str_find(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  @pattern.str_find_aux(state, args, true)
}

///|
pub fn str_match(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  @pattern.str_find_aux(state, args, false)
}

///|----------------------------------------------------------------
/// `gmatch`

///|----------------------------------------------------------------

///|
/// The iterator returned by `gmatch`, carrying the subject, the pattern and the
/// position it has reached.  Because the state lives in the iterator itself,
/// several iterations of the same pattern can be active at once.
///
/// A leading `^` is *not* an anchor here: `gmatch` hands the pattern to the
/// matcher unchanged, so the caret is an ordinary character, and `gmatch("abc",
/// "^a")` finds nothing while `gmatch("^abc", "^a")` finds the caret.  `find`,
/// `match` and `gsub` do strip it.
pub fn gmatch_iterator(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = args
  let src = match upvals[0] {
    @core.VStr(s) => s
    _ => @core.LStr::empty()
  }
  let pat = match upvals[1] {
    @core.VStr(s) => s
    _ => @core.LStr::empty()
  }
  let mut pos = match upvals[2] {
    @core.VInt(i) => i.to_int()
    _ => 0
  }
  let lastmatch = match upvals[3] {
    @core.VInt(i) => i.to_int()
    _ => -1
  }
  let ms = @pattern.MatchState::new(src.data(), pat.data())
  while pos <= src.length() {
    ms.reset_captures()
    let res = @pattern.do_match(ms, pos, 0)
    match res {
      Some(e) =>
        // A match that ends where the previous one ended is the same empty
        // match repeating; skip it and keep scanning, as `gmatch_aux` does.
        if e == lastmatch {
          ()
        } else {
          upgrade_upval(state, upvals, 2, @core.VInt(e.to_int64()))
          upgrade_upval(state, upvals, 3, @core.VInt(e.to_int64()))
          return @pattern.push_captures(ms, pos, e)
        }
      None => ()
    }
    pos = pos + 1
  }
  [@core.VNil]
}

///|
pub fn str_gmatch(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "gmatch")
  let p = @core.check_str(state, args, 2, "gmatch")
  let init = @pattern.pos_relat_init(
    @core.opt_int(state, args, 3, "gmatch", 1L),
    s.length(),
  )
  let b = @core.VBuiltin(
    @core.make_builtin("gmatch_iterator", @core.BK_NORMAL, 0, gmatch_iterator, [
      @core.VStr(s),
      @core.VStr(p),
      @core.VInt(init.to_int64()),
      @core.VInt(-1L),
    ]),
  )
  let _ = state.registry.set_lstr(@core.LStr::of_string("__gmatch_last"), b)
  [b]
}

///|----------------------------------------------------------------
/// `gsub`

///|----------------------------------------------------------------

///|
/// Replaces every match of a pattern.  `repl` may be a string with `%n`
/// references, a table indexed by the first capture, or a function called with
/// the captures.
pub fn str_gsub(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "gsub")
  let p = @core.check_str(state, args, 2, "gsub")
  // The replacement must be given, and be a string, a number, a function or a
  // table: `luaL_argexpected` reports a missing third argument the same way it
  // reports a wrong one, so `gsub("a", "b")` says `got no value`.
  let repl = if args.length() < 3 {
    @core.arg_error(
      state, 3, "gsub", "string/function/table expected, got no value",
    )
  } else {
    args[2]
  }
  match repl {
    @core.VStr(_)
    | @core.VInt(_)
    | @core.VNum(_)
    | @core.VFunc(_)
    | @core.VBuiltin(_)
    | @core.VTable(_) => ()
    _ =>
      @core.arg_error(
        state,
        3,
        "gsub",
        "string/function/table expected, got " +
        @core.type_error_name(state, repl),
      )
  }
  let src = s.data()
  let pat = p.data()
  let max_n = @core.opt_int(
    state,
    args,
    4,
    "gsub",
    (src.length() + 1).to_int64(),
  )
  let ms = @pattern.MatchState::new(src, pat)
  let buf = Buffer::Buffer(size_hint=src.length())
  let mut pstart = 0
  let mut anchor = false
  if pat.length() > 0 && @core.ubyte_at(pat, 0) == 94 {
    anchor = true
    pstart = 1
  }
  let mut pos = 0
  let mut last_match = -1
  let mut count = 0L
  let mut changed = false
  while count < max_n {
    ms.reset_captures()
    let res = @pattern.do_match(ms, pos, pstart)
    let mut matched = false
    match res {
      Some(e) =>
        if e != last_match {
          matched = true
          count = count + 1
          let captures = @pattern.push_captures(ms, pos, e)
          let value = match repl {
            @core.VStr(r) =>
              substitute_escapes(
                state,
                r.data(),
                captures,
                @core.bytes_slice(src, pos, e - pos),
              )
            @core.VInt(_) | @core.VNum(_) =>
              substitute_escapes(
                state,
                @core.number_to_bytes(repl),
                captures,
                @core.bytes_slice(src, pos, e - pos),
              )
            // The table is consulted through `lua_gettable`, so an `__index`
            // metamethod can supply the replacement.
            @core.VTable(_) =>
              @vm.gettable(
                state,
                repl,
                if captures.length() > 0 {
                  captures[0]
                } else {
                  @core.VNil
                },
                -1,
              )
            @core.VFunc(_) | @core.VBuiltin(_) => {
              state.current_thread.ny = state.current_thread.ny + 1
              let r = @vm.call_value(state, repl, captures, 1)
              state.current_thread.ny = state.current_thread.ny - 1
              if r.length() > 0 {
                r[0]
              } else {
                @core.VNil
              }
            }
            _ => @core.VNil
          }
          match value {
            @core.VNil | @core.VBool(false) =>
              buf.write_bytes(@core.bytes_slice(src, pos, e - pos).view())
            @core.VStr(v) => {
              // Any real substitution makes the result a new string; only an
              // entirely unchanged run reuses the original object.
              changed = true
              buf.write_bytes(v.data().view())
            }
            @core.VInt(_) | @core.VNum(_) => {
              changed = true
              buf.write_bytes(@core.number_to_bytes(value).view())
            }
            other => {
              let name = @core.type_error_name(state, other)
              @core.runtime_error(
                state,
                "invalid replacement value (a " + name + ")",
              )
            }
          }
          last_match = e
          pos = e
        }
      None => ()
    }
    if !matched {
      if pos < src.length() {
        buf.write_byte(src.at(pos))
        pos = pos + 1
      } else {
        break
      }
    }
    if anchor {
      break
    }
  }
  if !changed {
    return [@core.VStr(s), @core.VInt(count)]
  }
  if pos < src.length() {
    buf.write_bytes(src.view(start=pos))
  }
  [@core.VStr(@core.LStr::of_bytes(buf.to_bytes())), @core.VInt(count)]
}

///|
/// Expands `%n` references inside a replacement string.
pub fn substitute_escapes(
  state : @core.LuaState,
  repl : Bytes,
  captures : Array[@core.Value],
  whole : Bytes,
) -> @core.Value raise @core.LuaRaised {
  if repl.length() == 0 {
    return @core.VStr(@core.LStr::empty())
  }
  let buf = Buffer::Buffer(size_hint=repl.length())
  let mut i = 0
  while i < repl.length() {
    let c = @core.ubyte_at(repl, i)
    if c == 37 {
      i = i + 1
      let d = if i < repl.length() { @core.ubyte_at(repl, i) } else { -1 }
      if d == 37 {
        buf.write_byte(@core.byte_of(37))
        i = i + 1
      } else if d == 48 {
        // %0 refers to the whole match, always.
        buf.write_bytes(whole.view())
        i = i + 1
      } else if d >= 49 && d <= 57 {
        let idx = d - 49
        if idx >= captures.length() {
          @core.runtime_error(
            state,
            "invalid capture index %" + (idx + 1).to_string(),
          )
        }
        match captures[idx] {
          @core.VStr(v) => buf.write_bytes(v.data().view())
          @core.VInt(_) | @core.VNum(_) =>
            buf.write_bytes(@core.number_to_bytes(captures[idx]).view())
          _ => buf.write_bytes(whole.view())
        }
        i = i + 1
      } else {
        @core.runtime_error(state, "invalid use of '%' in replacement string")
      }
    } else {
      buf.write_byte(repl.at(i))
      i = i + 1
    }
  }
  @core.VStr(@core.LStr::of_bytes(buf.to_bytes()))
}

///|----------------------------------------------------------------
/// `format`

///|----------------------------------------------------------------
