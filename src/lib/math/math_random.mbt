// Pseudo random numbers.

///|
/// Projects a uniform 64 bit value onto `0..n` without bias, retrying when the
/// value falls in the incomplete tail of the range.  The tail is found by
/// filling the bits below the highest one of `n`, which is the smallest number
/// of the form 2^b - 1 that can hold `n`.
pub fn project_random(rv : UInt64, n : UInt64) -> UInt64 {
  let all_ones = 0xFFFFFFFFFFFFFFFFUL
  if n == all_ones || (n & (n + 1UL)) == 0UL {
    // 'n + 1' is a power of two, so every value projects exactly once.
    return n & rv
  }
  let mut lim = n
  lim = lim | (lim >> 1)
  lim = lim | (lim >> 2)
  lim = lim | (lim >> 4)
  lim = lim | (lim >> 8)
  lim = lim | (lim >> 16)
  lim = lim | (lim >> 32)
  let mut r = rv & lim
  while r > n {
    r = @host.lua_mbt_rng_next() & lim
  }
  r
}

///|
pub fn math_random(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let rv = @host.lua_mbt_rng_next()
  if args.length() == 0 {
    // A float in [0, 1) with 53 bits of precision.
    let mantissa = Double::convert_uint64(rv >> 11)
    return @core.One(@core.VNum(mantissa * (1.0 / 9007199254740992.0)))
  }
  if args.length() > 2 {
    @core.runtime_error(state, "wrong number of arguments")
  }
  let mut low = 1L
  let mut up = 1L
  if args.length() == 1 {
    up = @core.check_int(state, args, 1, "random")
    if up == 0L {
      return @core.One(@core.VInt(rv.reinterpret_as_int64()))
    }
  } else {
    low = @core.check_int(state, args, 1, "random")
    up = @core.check_int(state, args, 2, "random")
  }
  if low > up {
    @core.arg_error(state, 1, "random", "interval is empty")
  }
  let span = (up - low).reinterpret_as_uint64()
  let p = project_random(rv, span)
  @core.One(
    @core.VInt((p + low.reinterpret_as_uint64()).reinterpret_as_int64()),
  )
}

///|
pub fn math_randomseed(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  // The seeds are both handed back, so that resuming from them repeats the
  // sequence, which is how a test checks that the state really is reproducible.
  // Only a call with no argument at all seeds from the clock: an explicit nil
  // is a value the numeric check refuses (`lua_isnone`, not `lua_isnoneornil`).
  let seeds = if args.length() == 0 {
    [@host.lua_mbt_rng_time_seed(), @host.lua_mbt_rng_addr_seed()]
  } else {
    [
      @core.check_int(state, args, 1, "randomseed").reinterpret_as_uint64(),
      @core.opt_int(state, args, 2, "randomseed", 0L).reinterpret_as_uint64(),
    ]
  }
  @host.lua_mbt_rng_seed(seeds[0], seeds[1])
  @core.Two(
    @core.VInt(seeds[0].reinterpret_as_int64()),
    @core.VInt(seeds[1].reinterpret_as_int64()),
  )
}

///|----------------------------------------------------------------
/// Installation

///|----------------------------------------------------------------
