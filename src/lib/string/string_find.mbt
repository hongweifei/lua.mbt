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
  // Nothing left: the reference's `gmatch_aux` answers with *no* values here,
  // and the difference is visible -- `select("#", it())` is 0, not 1.
  []
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
  // A string or a number is appended as text; a function or a table is called
  // for a value.  The text is the same for every match, so whether it names a
  // capture or the whole match is decided once, here.
  let repl_text : Bytes? = match repl {
    @core.VStr(r) => Some(r.data())
    @core.VInt(_) | @core.VNum(_) => Some(@core.number_to_bytes(repl))
    _ => None
  }
  let repl_plain = match repl_text {
    Some(t) => !contains_byte(t, 37)
    None => false
  }
  while count < max_n {
    ms.reset_captures()
    let res = @pattern.do_match(ms, pos, pstart)
    let mut matched = false
    match res {
      Some(e) =>
        if e != last_match {
          matched = true
          count = count + 1
          match repl_text {
            Some(text) => {
              // Any substitution makes the result a new string, even when the
              // replacement is the text it replaced.
              changed = true
              if repl_plain {
                buf.write_bytes(text.view())
              } else {
                add_substitution(state, buf, ms, src, pos, e, text)
              }
            }
            None => {
              let captures = @pattern.push_captures(ms, pos, e)
              let value = match repl {
                // The table is consulted through `lua_gettable`, so an
                // `__index` metamethod can supply the replacement.
                @core.VTable(_) =>
                  @vm.index_get(
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
              // A nil or false answer keeps the text that was there, which is
              // the one case where the result is not a new string.
              match value {
                @core.VNil | @core.VBool(false) =>
                  buf.write_bytes(src.view(start=pos, end=e))
                @core.VStr(v) => {
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
/// Whether the byte `c` occurs in `b`.
fn contains_byte(b : Bytes, c : Int) -> Bool {
  let mut i = 0
  while i < b.length() {
    if @core.ubyte_at(b, i) == c {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Appends one replacement to the accumulated result, expanding `%n` references
/// as it goes.  This is the reference's `add_s`, and the reason it is written as
/// "append into the result" rather than "build the replacement string, then
/// append that" is that the second shape allocates a buffer, its bytes and a
/// string object for every match of a `gsub`.
///
/// A capture is read only where the replacement names one, so a match that
/// nothing refers to costs nothing beyond the text itself.
fn add_substitution(
  state : @core.LuaState,
  buf : Buffer,
  ms : @pattern.MatchState,
  src : Bytes,
  s : Int,
  e : Int,
  repl : Bytes,
) -> Unit raise @core.LuaRaised {
  let n = repl.length()
  let mut at = 0
  while true {
    let hit = @core.bytes_index_of(repl, at, n - at, 37)
    if hit < 0 {
      buf.write_bytes(repl.view(start=at))
      return
    }
    buf.write_bytes(repl.view(start=at, end=hit))
    let mut i = hit + 1
    let c = if i < n { @core.ubyte_at(repl, i) } else { -1 }
    if c == 37 {
      // `%%` is a literal per cent sign.
      buf.write_byte(@core.byte_of(37))
      i = i + 1
    } else if c == 48 {
      // `%0` is the whole match, which is a range of the subject rather than a
      // capture, so it is written from there directly.
      buf.write_bytes(src.view(start=s, end=e))
      i = i + 1
    } else if c >= 49 && c <= 57 {
      let cap = @pattern.one_capture(ms, c - 49, s, e)
      match cap {
        @core.VStr(v) => buf.write_bytes(v.data().view())
        @core.VInt(_) | @core.VNum(_) =>
          buf.write_bytes(@core.number_to_bytes(cap).view())
        _ => ()
      }
      i = i + 1
    } else {
      @core.runtime_error(state, "invalid use of '%' in replacement string")
    }
    at = i
  }
}

///|----------------------------------------------------------------
/// `format`

///|----------------------------------------------------------------
