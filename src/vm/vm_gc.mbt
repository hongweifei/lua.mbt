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
/// One full collection, finalizers included.  Shared by `collectgarbage` and by
/// the automatic collection the interpreter asks for as memory grows.
pub fn collect_all(st : @core.LuaState) -> Unit raise @core.LuaRaised {
  let pending = @core.gc_collect(st)
  for v in pending {
    run_gc_finalizer(st, v)
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
pub fn collect_and_retune(st : @core.LuaState) -> Unit raise @core.LuaRaised {
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
