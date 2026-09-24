// debug.sethook / gethook.

///|
/// Parses a hook mask string into the bitmask ('c', 'r', 'l').  Anything else
/// in the string is ignored, which is `makemask`: it only tests for the three
/// letters, so `debug.sethook(f, "x")` sets a hook that never fires rather than
/// being an error.
fn hook_mask_of(s : @core.LStr) -> Int {
  let mut mask = 0
  let data = s.data()
  let mut i = 0
  while i < data.length() {
    match @core.ubyte_at(data, i) {
      99 => mask = mask | @core.HOOK_CALL // 'c'
      114 => mask = mask | @core.HOOK_RETURN // 'r'
      108 => mask = mask | @core.HOOK_LINE // 'l'
      _ => ()
    }
    i = i + 1
  }
  mask
}

///|
/// Renders a hook mask back to the canonical string form.
fn hook_mask_str(mask : Int) -> String {
  let b = StringBuilder()
  if (mask & @core.HOOK_CALL) != 0 {
    b.write_char('c')
  }
  if (mask & @core.HOOK_RETURN) != 0 {
    b.write_char('r')
  }
  if (mask & @core.HOOK_LINE) != 0 {
    b.write_char('l')
  }
  b.to_string()
}

///|
pub fn db_sethook(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let (thread, arg) = get_thread(st, args)
  let f = arg_or_nil(args, arg)
  // Turning hooks off is a call with no hook function, and nothing else is
  // checked then.  Otherwise the *mask* is what is checked first and the hook
  // function second (`db_sethook`: `luaL_checkstring(L, arg+2)`, then
  // `luaL_checktype(L, arg+1, LUA_TFUNCTION)`), so `debug.sethook({})` reports
  // the missing mask rather than the wrong function.
  let mut mask = 0
  let mut count = 0
  if !f.is_nil() {
    let smask = @core.check_str(st, args, arg + 1, "sethook")
    let _ = @core.check_function(st, args, arg, "sethook")
    count = @core.opt_int(st, args, arg + 2, "sethook", 0L).to_int()
    mask = hook_mask_of(smask)
  }
  // A positive count turns the count events on even when no letter in the mask
  // string asks for them, which is what `makemask` does.
  mask = if count > 0 { mask | @core.HOOK_COUNT } else { mask }
  // With nothing left to report there is no hook at all, however many
  // instructions it was asked to count.
  let f = if mask == 0 { @core.VNil } else { f }
  thread.hook_fn = f
  thread.hook_mask = mask
  thread.hook_base_count = if count > @core.HOOK_COUNT_MAX {
    @core.HOOK_COUNT_MAX
  } else {
    count
  }
  thread.hook_count = thread.hook_base_count
  @vm.set_traps(thread)
  []
}

///|
// The builtin callback type demands a `raise`; this function never uses it.
#warnings("-unused_error_type")
pub fn db_gethook(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = st
  let (thread, _arg) = get_thread(st, args)
  match thread.hook_fn {
    @core.VNil => [@core.VNil]
    _ =>
      [
        thread.hook_fn,
        @core.VStr(@core.LStr::of_string(hook_mask_str(thread.hook_mask))),
        @core.VInt(thread.hook_base_count.to_int64()),
      ]
  }
}
