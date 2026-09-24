// The pattern matcher.

///|
pub const L_ESC : Int = 37

///|
/// A capture that has been opened but not closed yet.
pub const CAP_UNFINISHED : Int = -1

///|
/// A capture that records a position rather than a substring.
pub const CAP_POSITION : Int = -2

///|
/// Maximum number of nested captures.
pub const MAX_CAPTURES : Int = 32

///|
/// Maximum pattern nesting, matching the reference implementation's limit.
pub const MAX_PATTERN_DEPTH : Int = 200

///|
/// Matches the pattern against the subject, tracking captures in place.
pub(all) struct MatchState {
  src : Bytes
  pat : Bytes
  capture_start : Array[Int]
  capture_len : Array[Int]
  mut level : Int
  mut depth : Int
  /// Set when the last capture opened was a position capture, so that
  /// `get_capture` can tell the two kinds apart.
  error : Bytes
}

///|
pub fn MatchState::new(src : Bytes, pat : Bytes) -> MatchState {
  let starts : Array[Int] = []
  let lens : Array[Int] = []
  let mut i = 0
  while i < MAX_CAPTURES {
    starts.push(0)
    lens.push(CAP_UNFINISHED)
    i = i + 1
  }
  {
    src,
    pat,
    capture_start: starts,
    capture_len: lens,
    level: 0,
    depth: 0,
    error: Bytes::new(0),
  }
}

///|
pub fn[T] MatchState::fail(
  self : MatchState,
  msg : String,
) -> T raise @core.LuaRaised {
  let _ = self
  raise @core.LuaRaised(@core.VStr(@core.LStr::of_string(msg)))
}

///|
pub fn MatchState::reset_captures(self : MatchState) -> Unit {
  self.level = 0
  let mut i = 0
  while i < MAX_CAPTURES {
    self.capture_len[i] = CAP_UNFINISHED
    i = i + 1
  }
}

///|----------------------------------------------------------------
/// Character classes

///|----------------------------------------------------------------

///|
pub fn check_capture(ms : MatchState, l : Int) -> Int raise @core.LuaRaised {
  let idx = l - 49
  if idx < 0 || idx >= ms.level || ms.capture_len[idx] == CAP_UNFINISHED {
    ms.fail("invalid capture index %" + (idx + 1).to_string())
  }
  idx
}

///|
pub fn capture_to_close(ms : MatchState) -> Int raise @core.LuaRaised {
  let mut level = ms.level - 1
  while level >= 0 {
    if ms.capture_len[level] == CAP_UNFINISHED {
      return level
    }
    level = level - 1
  }
  ms.fail("invalid pattern capture")
}

///|
/// Matches a back reference `%1`..`%9`.
pub fn match_capture(
  ms : MatchState,
  s : Int,
  l : Int,
) -> Int? raise @core.LuaRaised {
  let idx = check_capture(ms, l)
  let len = ms.capture_len[idx]
  // A position capture holds no bytes to compare.  The reference's length test
  // is on a `size_t`, so the negative marker makes it fail: a back reference to
  // a position never matches.
  if len == CAP_POSITION {
    return None
  }
  let start = ms.capture_start[idx]
  if ms.src.length() - s >= len &&
    @core.bytes_equal_range(ms.src, start, ms.src, s, len) {
    Some(s + len)
  } else {
    None
  }
}

///|
/// `%bxy`: matches a balanced sequence.
pub fn match_balance(
  ms : MatchState,
  s : Int,
  p : Int,
) -> Int? raise @core.LuaRaised {
  if p + 1 >= ms.pat.length() {
    ms.fail("malformed pattern (missing arguments to '%b')")
  }
  if s >= ms.src.length() ||
    @core.ubyte_at(ms.src, s) != @core.ubyte_at(ms.pat, p) {
    return None
  }
  let b = @core.ubyte_at(ms.pat, p)
  let e = @core.ubyte_at(ms.pat, p + 1)
  let mut cont = 1
  let mut i = s + 1
  while i < ms.src.length() {
    let c = @core.ubyte_at(ms.src, i)
    if c == e {
      cont = cont - 1
      if cont == 0 {
        return Some(i + 1)
      }
    } else if c == b {
      cont = cont + 1
    }
    i = i + 1
  }
  None
}

///|
/// Starts a capture and continues matching.
pub fn start_capture(
  ms : MatchState,
  s : Int,
  p : Int,
  what : Int,
) -> Int? raise @core.LuaRaised {
  let level = ms.level
  if level >= MAX_CAPTURES {
    ms.fail("too many captures")
  }
  ms.capture_len[level] = what
  ms.capture_start[level] = s
  ms.level = level + 1
  let res = do_match(ms, s, p)
  if res is None {
    ms.level = ms.level - 1
  }
  res
}

///|
/// Closes the innermost open capture and continues matching.
pub fn end_capture(
  ms : MatchState,
  s : Int,
  p : Int,
) -> Int? raise @core.LuaRaised {
  let l = capture_to_close(ms)
  ms.capture_len[l] = s - ms.capture_start[l]
  let res = do_match(ms, s, p)
  if res is None {
    ms.capture_len[l] = CAP_UNFINISHED
  }
  res
}

///|----------------------------------------------------------------
/// The matcher

///|----------------------------------------------------------------

///|
/// Matches `pat` at `p` against `src` at `s`.  Returns the index just past the
/// match, or `None` when the pattern does not match here.
pub fn do_match(
  ms : MatchState,
  s : Int,
  p : Int,
) -> Int? raise @core.LuaRaised {
  ms.depth = ms.depth + 1
  if ms.depth > MAX_PATTERN_DEPTH {
    ms.depth = ms.depth - 1
    ms.fail("pattern too complex")
  }
  let si = s
  let pi = p
  let result : Int? = match_loop(ms, si, pi)
  ms.depth = ms.depth - 1
  result
}

///|
/// The body of `do_match`, written as a loop so that the tail recursive steps of
/// the reference implementation do not consume host stack.
pub fn match_loop(
  ms : MatchState,
  s0 : Int,
  p0 : Int,
) -> Int? raise @core.LuaRaised {
  let mut si = s0
  let mut pi = p0
  while pi < ms.pat.length() {
    let c = @core.ubyte_at(ms.pat, pi)
    if c == 40 {
      // '(' starts a capture, or records a position when followed by ')'.
      if pi + 1 < ms.pat.length() && @core.ubyte_at(ms.pat, pi + 1) == 41 {
        return start_capture(ms, si, pi + 2, CAP_POSITION)
      }
      return start_capture(ms, si, pi + 1, CAP_UNFINISHED)
    }
    if c == 41 {
      return end_capture(ms, si, pi + 1)
    }
    if c == 36 && pi + 1 == ms.pat.length() {
      // '$' at the end anchors the match to the end of the subject.
      if si == ms.src.length() {
        return Some(si)
      }
      return None
    }
    if c == L_ESC {
      let next = if pi + 1 < ms.pat.length() {
        @core.ubyte_at(ms.pat, pi + 1)
      } else {
        -1
      }
      if next == 98 {
        match match_balance(ms, si, pi + 2) {
          None => return None
          Some(ns) => {
            si = ns
            pi = pi + 4
            continue
          }
        }
      }
      if next == 102 {
        // %f[set]: a frontier, an empty match between a non member and a member.
        let set_start = pi + 2
        if set_start >= ms.pat.length() ||
          @core.ubyte_at(ms.pat, set_start) != 91 {
          ms.fail("missing '[' after '%f' in pattern")
        }
        let ep = class_end(ms, set_start)
        let previous = if si == 0 { 0 } else { @core.ubyte_at(ms.src, si - 1) }
        let current = if si < ms.src.length() {
          @core.ubyte_at(ms.src, si)
        } else {
          0
        }
        if !match_bracket_class(previous, ms.pat, set_start, ep - 1) &&
          match_bracket_class(current, ms.pat, set_start, ep - 1) {
          pi = ep
          continue
        }
        return None
      }
      if next >= 48 && next <= 57 {
        match match_capture(ms, si, next) {
          None => return None
          Some(ns) => {
            si = ns
            pi = pi + 2
            continue
          }
        }
      }
    }
    // A single class with an optional quantifier.
    let ep = class_end(ms, pi)
    let suffix = if ep < ms.pat.length() {
      @core.ubyte_at(ms.pat, ep)
    } else {
      -1
    }
    if !single_match(ms, si, pi, ep) {
      if suffix == 42 || suffix == 63 || suffix == 45 {
        pi = ep + 1
        continue
      }
      return None
    }
    if suffix == 63 {
      let res = do_match(ms, si + 1, ep + 1)
      match res {
        Some(r) => return Some(r)
        None => {
          pi = ep + 1
          continue
        }
      }
    }
    if suffix == 43 {
      return max_expand(ms, si + 1, pi, ep)
    }
    if suffix == 42 {
      return max_expand(ms, si, pi, ep)
    }
    if suffix == 45 {
      return min_expand(ms, si, pi, ep)
    }
    si = si + 1
    pi = ep
  }
  Some(si)
}

///|
/// Greedy repetition.
pub fn max_expand(
  ms : MatchState,
  s : Int,
  p : Int,
  ep : Int,
) -> Int? raise @core.LuaRaised {
  let mut i = 0
  while single_match(ms, s + i, p, ep) {
    i = i + 1
  }
  while i >= 0 {
    let res = do_match(ms, s + i, ep + 1)
    match res {
      Some(r) => return Some(r)
      None => ()
    }
    i = i - 1
  }
  None
}

///|
/// Lazy repetition.
pub fn min_expand(
  ms : MatchState,
  s : Int,
  p : Int,
  ep : Int,
) -> Int? raise @core.LuaRaised {
  let mut si = s
  while true {
    let res = do_match(ms, si, ep + 1)
    match res {
      Some(r) => return Some(r)
      None => ()
    }
    if single_match(ms, si, p, ep) {
      si = si + 1
    } else {
      return None
    }
  }
  None
}

///|----------------------------------------------------------------
/// Results

///|----------------------------------------------------------------
