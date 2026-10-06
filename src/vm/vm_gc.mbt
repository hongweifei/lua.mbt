// Running what the collector asks for.
//
// The collector itself lives in `core`, which cannot call a Lua function.  It
// hands back the objects whose `__gc` is due, and this layer calls them.

///|
/// Calls the `__gc` of a value the collector decided is unreachable.  The
/// handler runs under the name `__gc`, which is what `debug.getinfo` reports
/// for its frame (`db.lua` checks namewhat "metamethod" and that name).
pub fn run_gc_finalizer(
  st : @core.LuaState,
  v : @core.Value,
) -> Unit raise @core.LuaRaised {
  match metatable_of(st, v) {
    Some(mt) => {
      let h = mt.hash_get(@core.KStr(@core.LStr::of_string("__gc")))
      if !h.is_nil() {
        // A collection started from here would be a collection inside a
        // collection, so the collector is closed for the duration and every
        // `collectgarbage` option answers false (`GCSTPGC`).
        let saved = st.gc_finalizing
        st.gc_finalizing = true
        let _ = call_metamethod(st, h, [v], 0, "__gc")
        st.gc_finalizing = saved
      }
    }
    None => ()
  }
}

///|
/// The reference's `GCTM`: the handler is called where nobody can receive an
/// error -- the collector is the caller -- so a failure becomes the warning
/// `error in __gc (<msg>)` and the run goes on.  The message is the error object
/// when it is a string and `error object is not a string` otherwise; a handler
/// that yields is refused by the same boundary every other host call enforces,
/// and that refusal is what gets reported.
///
/// `luaD_pcall` is given an error function of 0, so the message handler that is
/// installed where the collection happens -- the launcher's, or an enclosing
/// `xpcall`'s -- is skipped: what reaches the warning is the error as it was
/// raised, with its position but without the traceback a handler would have
/// added.  Hooks are switched off for the duration (`L->allowhook = 0`), so a
/// finalizer runs untraced: a line or count hook reports nothing of what the
/// handler does, and its instructions do not run down a count either.
fn finalizer_call(st : @core.LuaState, v : @core.Value) -> Unit {
  let thread = st.current_thread
  let saved_errfunc = thread.errfunc
  let saved_allowhook = thread.allowhook
  thread.errfunc = @core.VNil
  thread.allowhook = false
  let failed = try {
    run_gc_finalizer(st, v)
    None
  } catch {
    @core.LuaRaised(err) => Some(@core.error_for_warning(err))
    @core.LuaYield(_) => Some(@core.bytes_of(yield_error(st, thread)))
  }
  thread.errfunc = saved_errfunc
  thread.allowhook = saved_allowhook
  match failed {
    Some(msg) =>
      @core.warn_message(
        st,
        @core.bytes_concat([
          @core.bytes_of("error in __gc ("),
          msg,
          @core.bytes_of(")"),
        ]),
      )
    None => ()
  }
}

///|
/// Closing the state, which is what `lua_close` does and what the reference's
/// `pmain` reaches at the end of a run: every object with a `__gc` gets one, in
/// the order a collection would finalize them, whether or not anything still
/// holds it.  This is why a finalizer can print after the script is over -- and
/// why `os.exit(code)` without the `close` flag does not print it: the reference
/// calls `exit(status)` straight away there.
///
/// No new handler is registered from here on (the reference's `GCSTPCLS`), so one
/// pass is enough: nothing a handler resurrects can join the list.
pub fn close_state(st : @core.LuaState) -> Unit {
  st.gc_closing = true
  for v in @core.gc_all_finalizers(st) {
    finalizer_call(st, v)
  }
}

///|
/// `setpause`: what a finished cycle leaves behind.  The debt is the distance to
/// the next threshold, which is negative while the live set is below it -- a
/// credit, and until it is paid off `collectgarbage("step")` does no work at all.
pub fn ledger_finish_cycle(st : @core.LuaState) -> Unit {
  st.gc_units_done = 0
  let credit = st.memory_units - st.gc_threshold
  st.gc_debt = if credit < 0 { credit } else { 0 }
}

///|
/// The work one cycle owes, in the units the debt arithmetic counts in (bytes
/// over `WORK2MEM`, i.e. one slot): one unit per object to mark plus one for
/// every `WORK2MEM` bytes they hold, one per object to sweep, and one for the
/// phases themselves.  What a cycle can know about the heap is what the last one
/// reached, so that is what stands for it.
fn cycle_units(st : @core.LuaState) -> Int {
  let objects = if st.gc_marked > 0 { st.gc_marked } else { 1 }
  objects + st.gc_marked_size / @core.WORK2MEM + objects + 1
}

///|
/// `lua_gc(L, LUA_GCSTEP, size)` and the `incstep` behind it: one step of the
/// collector, and whether it finished a cycle.
///
/// A collection here is atomic, so what is simulated is the *accounting* the
/// reference decides with.  Three of its rules do the work:
/// - the answer is "the debt was paid off *and* the collector is sitting at its
///   pause state", not "a cycle ended"; a generational collection -- minor or
///   major, with the collector running or stopped -- never leaves the state
///   machine at the pause state, so in that mode a step never answers `true`;
/// - a sized step only reaches the collector through `luaC_checkGC`, which steps
///   only when the debt is positive -- so a step taken while the credit from the
///   last collection is unpaid does *nothing*;
/// - a step that does run pays for `debt + the granularity` worth of work, which
///   is why a basic step (`size` 0) has room for a small heap's whole cycle and
///   answers `true` there, while on a large one it answers `false`.
/// `setstepmul` scales both figures, as it does there -- it is an `incstep`
/// parameter, so in generational mode it changes nothing.
pub fn gc_step(st : @core.LuaState, size : Int) -> Bool {
  let finished = gc_step_work(st, size)
  finished && st.gc_mode != "generational"
}

///|
/// The accounting of one step, without the mode that asks for it.
fn gc_step_work(st : @core.LuaState, size : Int) -> Bool {
  // `lua_gc`: a basic step clears the debt and steps at once; a sized one adds
  // its kilobytes and lets `luaC_checkGC` decide whether that pays for a step.
  if size == 0 {
    st.gc_debt = 0
  } else {
    let asked = size.to_int64() * 1024L + st.gc_debt.to_int64()
    let debt = if asked > @core.GC_MAX_DEBT {
      @core.GC_MAX_DEBT
    } else if asked < -@core.GC_MAX_DEBT {
      -@core.GC_MAX_DEBT
    } else {
      asked
    }
    st.gc_debt = debt.to_int()
    if debt <= 0L {
      return false
    }
  }
  // `incstep`: the work this step pays for, in units of one slot, plus the
  // granularity one step is worth.  `stepmul` scales both, and the `| 1` is the
  // reference's guard against a multiplier of zero.
  let stepmul = (if st.gc_stepmul < 0 { 0 } else { st.gc_stepmul }) | 1
  let units = st.gc_debt.to_int64() /
    @core.WORK2MEM.to_int64() *
    stepmul.to_int64() +
    (1L << @core.GC_STEP_SHIFT) / @core.WORK2MEM.to_int64() * stepmul.to_int64()
  let paid = if units < 1L { 1L } else { units }
  let done = st.gc_units_done.to_int64() + paid
  if done >= cycle_units(st).to_int64() {
    // The cycle is paid for: the collection runs, and `setpause` leaves its
    // credit for the steps that follow.
    collect_and_retune(st)
    ledger_finish_cycle(st)
    true
  } else {
    st.gc_units_done = done.to_int()
    // What the phase loop leaves behind is the credit of the granularity it did
    // not spend (`debt / stepmul * WORK2MEM` with the debt the loop stopped at),
    // which is what the next steps have to pay off before they do any work.
    st.gc_debt = -(1 << @core.GC_STEP_SHIFT)
    false
  }
}

///|
/// One full collection, finalizers included.  Shared by `collectgarbage` and by
/// the automatic collection the interpreter asks for as memory grows.  A handler
/// that fails here is reported as a warning and the collection goes on, as the
/// reference's `GCTM` does, so nothing this calls raises out.
pub fn collect_all(st : @core.LuaState) -> Unit {
  let pending = @core.gc_collect(st)
  for v in pending {
    finalizer_call(st, v)
  }
}

///|
/// The least a program may allocate between two automatic collections, so that
/// a small live set does not make the collector run on every instruction.
pub const GC_FLOOR : Int = 4 * 1024

///|
/// The largest threshold a pause parameter may ask for.  `setpause` takes an
/// arbitrary integer, and the reference simply multiplies by it; a product that
/// does not fit would wrap here and make the threshold negative, which would
/// collect on every instruction.
pub const GC_MAX_THRESHOLD : Int = 0x7fff_ffff

///|
/// A full collection and the threshold for the next automatic one.  The
/// collector leaves the live size in `memory_units`, and the pause parameter
/// says how far past it the next collection is due -- the reference's
/// `GCthreshold`, set from `totalbytes` and `gcpause`.
pub fn collect_and_retune(st : @core.LuaState) -> Unit {
  // Nothing may collect while a collection is under way: a `__gc` handler runs
  // Lua, and its first instruction would find the old threshold still passed.
  st.gc_threshold = st.memory_units + @core.GC_STEP
  collect_all(st)
  // The live size is in bytes and the pause is a percentage, so the product
  // needs room: on a live set of a few megabytes it overflows a 32-bit `Int`.
  // A pause the program sets can be enormous, so the result is capped rather
  // than wrapped -- a wrapped threshold would be negative, and every
  // instruction would then collect.
  let mut due = st.memory_units.to_int64() * st.gc_pause.to_int64() / 100L
  if due > GC_MAX_THRESHOLD.to_int64() {
    due = GC_MAX_THRESHOLD.to_int64()
  }
  let due = due.to_int()
  st.gc_threshold = if due > GC_FLOOR { due } else { GC_FLOOR }
  st.gc_debt = 0
}
