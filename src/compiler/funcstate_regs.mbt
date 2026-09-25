// Register window and constant pool of the compiler state.

///|
/// Moves the temporary window, remembering the high water mark so that the
/// frame reserves enough stack slots.
pub fn FuncState::set_freereg(self : FuncState, v : Int) -> Unit {
  self.freereg = v
  if v > self.maxstack {
    self.maxstack = v
  }
}

///|
/// Reserves `n` consecutive registers above the active locals.
pub fn FuncState::reserve(
  self : FuncState,
  n : Int,
) -> Unit raise @core.LuaRaised {
  self.check_regs(self.freereg + n)
  self.set_freereg(self.freereg + n)
}

///|
/// `luaK_checkstack`: growing the register window to `upto` is refused once the
/// instruction encoding can no longer name the registers involved.
pub fn FuncState::check_regs(
  self : FuncState,
  upto : Int,
) -> Unit raise @core.LuaRaised {
  if upto >= @core.MAX_REGS {
    self.too_many_registers()
  }
}

///|
/// Releases every register at or above `reg`.
pub fn FuncState::free_from(self : FuncState, reg : Int) -> Unit {
  if reg < self.freereg && reg >= self.nactive {
    self.set_freereg(reg)
  }
}

///|
/// Resets the temporaries, keeping the active locals.
pub fn FuncState::free_all(self : FuncState) -> Unit {
  self.set_freereg(self.nactive)
}

///|----------------------------------------------------------------
/// Constants

///|----------------------------------------------------------------

///|
/// Adds a constant to the pool, reusing an existing entry when the value is
/// already there.  The three kinds that dominate a real chunk each have a
/// cache keyed by a value the map takes as it stands -- a string by its own
/// interned object, an integer by itself, a float by its bit pattern, which is
/// what `const_key` uses too -- so no `Key` is built per lookup.
pub fn FuncState::add_constant(self : FuncState, v : @core.Value) -> Int {
  let cached : Int? = match v {
    @core.VStr(s) => self.kcache_str.get(s)
    @core.VInt(i) => self.kcache_int.get(i)
    @core.VNum(d) => self.kcache_num.get(d.reinterpret_as_uint64())
    _ => self.kcache.get(@core.const_key(v))
  }
  match cached {
    Some(idx) => idx
    None => self.remember_constant(v)
  }
}

///|
/// Appends a constant that was not in the cache and remembers where it went.
fn FuncState::remember_constant(self : FuncState, v : @core.Value) -> Int {
  let idx = self.constants.length()
  self.constants.push(v)
  match v {
    @core.VStr(s) => self.kcache_str[s] = idx
    @core.VInt(i) => self.kcache_int[i] = idx
    @core.VNum(d) => self.kcache_num[d.reinterpret_as_uint64()] = idx
    _ => self.kcache.set(@core.const_key(v), idx)
  }
  idx
}

///|
pub fn FuncState::add_string(self : FuncState, s : @core.LStr) -> Int {
  self.add_constant(@core.VStr(s))
}

///|
/// Emits a load of a constant into a register.
pub fn FuncState::load_const(
  self : FuncState,
  reg : Int,
  v : @core.Value,
) -> Unit {
  let k = self.add_constant(v)
  let _ = self.emit_ab(@core.OP_LOADK, reg, k)
}

///|
/// Loads nil into `n` consecutive registers starting at `reg`.
pub fn FuncState::load_nil(self : FuncState, reg : Int, n : Int) -> Unit {
  let mut i = 0
  while i < n {
    let _ = self.emit_ab(@core.OP_LOADNIL, reg + i, 1)
    i = i + 1
  }
}

///|----------------------------------------------------------------
/// Jumps

///|----------------------------------------------------------------
