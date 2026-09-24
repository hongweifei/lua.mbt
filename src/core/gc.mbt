// The collector: reachability, weak tables and finalization.
//
// Memory belongs to the host runtime, which reclaims it by reference counting,
// so the only thing that leaks is a cycle.  Nothing here frees anything.  What
// it decides is what is *reachable* from the roots, and then applies the three
// rules that need that answer: a weak table drops an entry whose object key or
// value is unreachable, an ephemeron's value counts as reachable only through a
// key that is reachable itself, and an unreachable object with a `__gc` gets its
// farewell call.
//
// Reachability is computed by marking from the roots and following values, which
// is why no list of every allocated object is needed and no sweep follows it.
// The only objects registered are the ones that ask to be looked at every cycle:
// tables whose metatable carries a `__mode`, and objects whose metatable carries
// a `__gc`.

///|
/// Whether a `__mode` string asks for the keys to be weak.
fn mode_weak_keys(mode : String) -> Bool {
  mode.contains("k")
}

///|
/// Whether a `__mode` string asks for the values to be weak.
fn mode_weak_values(mode : String) -> Bool {
  mode.contains("v")
}

///|
/// The `__mode` of the metatable `mt`, empty when there is none.
fn metatable_mode(mt : LTable) -> String {
  match mt.hash_get(KStr(LStr::of_string("__mode"))) {
    VStr(s) => text_of(s.data())
    _ => ""
  }
}

///|
/// Whether a value is one the collector can carry an opinion about.  Strings
/// and numbers are values, not objects: a weak table never drops them, and a
/// `__gc` on them is not a thing.
pub fn gc_collectable(v : Value) -> Bool {
  match v {
    VTable(_) | VFunc(_) | VBuiltin(_) | VThread(_) => true
    VUserData(u) => !u.light
    _ => false
  }
}

///|
/// Whether the collector reached this value in the current cycle.  Anything it
/// cannot hold is reachable by definition.
fn gc_reached(st : LuaState, v : Value) -> Bool {
  match v {
    VTable(t) => t.mark_epoch == st.gc_epoch
    VFunc(c) => c.mark_epoch == st.gc_epoch
    VBuiltin(b) => b.mark_epoch == st.gc_epoch
    VThread(th) => th.mark_epoch == st.gc_epoch
    VUserData(u) => u.light || u.mark_epoch == st.gc_epoch
    _ => true
  }
}

///|
/// Notes an object whose metatable asks for attention, which is where a weak
/// table or a finalizable object enters the collector's view.  Called whenever
/// a metatable is attached.
pub fn gc_register(st : LuaState, v : Value) -> Unit {
  let mt = match v {
    VTable(t) => t.meta
    VUserData(u) => u.meta
    _ => None
  }
  match mt {
    None => ()
    Some(m) => {
      if metatable_mode(m) != "" {
        match v {
          VTable(t) => {
            let mut known = false
            for k in st.weak_tables {
              if k.id == t.id {
                known = true
              }
            }
            if !known {
              st.weak_tables.push(t)
            }
          }
          _ => ()
        }
      }
      let has_gc = match m.hash_get(KStr(LStr::of_string("__gc"))) {
        VNil => false
        _ => true
      }
      if has_gc {
        let mut known = false
        for k in st.finalizers {
          if k.raw_equal(v) {
            known = true
          }
        }
        if !known {
          st.finalizers.push(v)
        }
      }
    }
  }
}

///|
/// The bytes a table's parts hold.  This is the bulk of what a program that
/// only fills a table allocates, so it is also what the interpreter's budget is
/// spent on.
pub fn table_bytes(t : LTable) -> Int {
  t.hkeys.length() * 32 + t.arr.length() * 16
}

///|
/// What an object costs, near enough for a size a program can watch: the fixed
/// part of the reference's structures plus the bytes their parts hold.
fn object_size(v : Value) -> Int {
  match v {
    VTable(t) => 56 + table_bytes(t)
    VFunc(c) => 40 + c.upvals.length() * 8
    VBuiltin(b) => 40 + b.upvals.length() * 8
    VThread(th) => 200 + th.stack.length() * 16
    VUserData(u) => 32 + u.uservalues.length() * 16
    _ => 0
  }
}

///|
/// Marks a value and, when that is news, queues it for its contents to be
/// followed.  Non-collectable values need no marking.
fn mark(st : LuaState, v : Value, work : Array[Value]) -> Unit {
  match v {
    VTable(t) =>
      if t.mark_epoch != st.gc_epoch {
        t.mark_epoch = st.gc_epoch
        st.gc_marked = st.gc_marked + 1
        st.gc_marked_size = st.gc_marked_size + object_size(v)
        work.push(v)
      }
    VFunc(c) =>
      if c.mark_epoch != st.gc_epoch {
        c.mark_epoch = st.gc_epoch
        st.gc_marked = st.gc_marked + 1
        st.gc_marked_size = st.gc_marked_size + object_size(v)
        work.push(v)
      }
    VBuiltin(b) =>
      if b.mark_epoch != st.gc_epoch {
        b.mark_epoch = st.gc_epoch
        st.gc_marked = st.gc_marked + 1
        st.gc_marked_size = st.gc_marked_size + object_size(v)
        work.push(v)
      }
    VThread(th) =>
      if th.mark_epoch != st.gc_epoch {
        th.mark_epoch = st.gc_epoch
        st.gc_marked = st.gc_marked + 1
        st.gc_marked_size = st.gc_marked_size + object_size(v)
        work.push(v)
      }
    VUserData(u) =>
      if !u.light && u.mark_epoch != st.gc_epoch {
        u.mark_epoch = st.gc_epoch
        st.gc_marked = st.gc_marked + 1
        st.gc_marked_size = st.gc_marked_size + object_size(v)
        work.push(v)
      }
    // Strings are values here, but their bytes are the bulk of what a program
    // allocates, so a measurement has to carry them.  Equal strings share an
    // id, so counting once per id is counting once per string.
    VStr(s) =>
      if !st.gc_counted_strings.contains(s.id) {
        st.gc_counted_strings[s.id] = ()
        st.gc_marked_size = st.gc_marked_size + 24 + s.length()
      }
    _ => ()
  }
}

///|
/// Whether this table's metatable asks for a weak half.  Only such a table is
/// traversed partially; everything else is traversed whole.
fn weak_mode_of(t : LTable) -> String {
  match t.meta {
    Some(mt) => metatable_mode(mt)
    None => ""
  }
}

///|
/// Marks one half of a table entry.  When the half is weak, only a string is
/// still counted: strings are values here, and the reference keeps them in a
/// weak table for the same reason (`iscleared` marks a string rather than
/// reporting it as collectable).
fn mark_half(
  st : LuaState,
  v : Value,
  work : Array[Value],
  strong : Bool,
) -> Unit {
  if strong {
    mark(st, v, work)
  } else {
    match v {
      VStr(_) => mark(st, v, work)
      _ => ()
    }
  }
}

///|
/// Follows everything the queued values reach, until nothing new is found.
fn drain(st : LuaState, work : Array[Value]) -> Unit {
  // The queue has to be worked until it is empty: what a value reaches is
  // pushed *while* it is being looked at, so an index that only walked the
  // items that were there to begin with would drop everything past the first
  // level -- and the objects it dropped would then look unreachable to a weak
  // table.
  while work.length() > 0 {
    let v = work[work.length() - 1]
    work.truncate(work.length() - 1)
    match v {
      VTable(t) => {
        let mode = weak_mode_of(t)
        let weak_keys = mode_weak_keys(mode)
        let weak_values = mode_weak_values(mode)
        if !weak_values {
          for x in t.arr {
            mark(st, x, work)
          }
        } else {
          for x in t.arr {
            mark_half(st, x, work, false)
          }
        }
        let n = t.hkeys.length()
        let mut i = 0
        while i < n {
          // A removed entry keeps its key as a tombstone, so what makes a slot
          // live is a value, not a key.
          let live = !t.hvals[i].is_nil()
          if live {
            match t.hkeys[i] {
              KObj(k) => mark_half(st, k, work, !weak_keys)
              KStr(s) => mark_half(st, VStr(s), work, true)
              _ => ()
            }
            // A value is marked on its own only when the keys are strong too:
            // with weak keys the entry is an ephemeron, and the value waits for
            // a mark that comes from its own key (`traverseephemeron`).  Marking
            // it here would keep one link of an unreachable chain alive per
            // cycle instead of dropping the whole chain at once.
            mark_half(st, t.hvals[i], work, !weak_values && !weak_keys)
          }
          i = i + 1
        }
        match t.meta {
          Some(mt) => mark(st, VTable(mt), work)
          None => ()
        }
      }
      VFunc(c) =>
        for uv in c.upvals {
          mark(st, uv.get(), work)
        }
      VBuiltin(b) =>
        for uv in b.upvals {
          mark(st, uv, work)
        }
      VUserData(u) => {
        for x in u.uservalues {
          mark(st, x, work)
        }
        match u.meta {
          Some(mt) => mark(st, VTable(mt), work)
          None => ()
        }
      }
      VThread(th) => {
        // A frame's live region ends where the frame above it begins, and only
        // the innermost frame's window extends past its own call, because the
        // reference's mark phase stops at `L->top`: the registers a finished
        // expression left behind count as garbage, which is exactly what makes
        // `w[2] = {}; collectgarbage()` drop the entry below.
        let nf = th.frames.length()
        let mut live = 0
        let mut fi = 0
        while fi < nf {
          let fr = th.frames[fi]
          let end = if fi + 1 < nf {
            th.frames[fi + 1].func_slot
          } else {
            fr.top
          }
          if end > live {
            live = end
          }
          fi = fi + 1
        }
        if live > th.stack.length() {
          live = th.stack.length()
        }

        let mut si = 0
        while si < live {
          mark(st, th.stack[si], work)
          si = si + 1
        }
        for fr in th.frames {
          match fr.closure {
            Some(c) => mark(st, VFunc(c), work)
            None => ()
          }
          for a in fr.varargs {
            mark(st, a, work)
          }
          match fr.builtin {
            Some(b) =>
              for u in b.upvals {
                mark(st, u, work)
              }
            None => ()
          }
        }
        for cell in th.open_upvals {
          mark(st, cell.get(), work)
        }
        mark(st, th.func, work)
        mark(st, th.dead_error, work)
        match th.resume_vals {
          Some(vs) =>
            for x in vs {
              mark(st, x, work)
            }
          None => ()
        }
        match th.meta {
          Some(mt) => mark(st, VTable(mt), work)
          None => ()
        }
      }
      _ => ()
    }
  }
}

///|
/// The ephemeron rule: in a table whose keys are weak but whose values are not,
/// a value is reachable only through its own key, so it is marked only once the
/// key has been reached by something else.  Marking one value can reach the key
/// of another entry, so this repeats until it settles.
fn mark_ephemerons(st : LuaState, work : Array[Value]) -> Unit {
  let mut again = true
  while again {
    again = false
    for t in st.weak_tables {
      if weak_mode_of(t) == "k" {
        let n = t.hkeys.length()
        let mut i = 0
        while i < n {
          match t.hkeys[i] {
            KObj(k) =>
              if gc_reached(st, k) && gc_collectable(t.hvals[i]) {
                if !gc_reached(st, t.hvals[i]) {
                  mark(st, t.hvals[i], work)
                  drain(st, work)
                  again = true
                }
              }
            _ => ()
          }
          i = i + 1
        }
      }
    }
  }
}

///|
/// Drops the entries of every registered weak table that name something the
/// cycle did not reach.  An object key that is gone takes the whole entry with
/// it; a weak value is replaced by nil.

///|
/// Drops the values a weak table can no longer keep, for the tables whose mode
/// is exactly `mode`.  The reference runs this *before* the objects awaiting
/// finalization are resurrected, which is what lets such an object free a value
/// from a weak table while a weak *key* that points at it still survives
/// (`gc.lua:314`).
fn clear_weak_values(st : LuaState, mode : String) -> Unit {
  for t in st.weak_tables {
    if weak_mode_of(t) == mode {
      let mut i = 0
      while i < t.arr.length() {
        if gc_collectable(t.arr[i]) && !gc_reached(st, t.arr[i]) {
          t.arr[i] = VNil
        }
        i = i + 1
      }
      clear_values_of(st, t)
    }
  }
}

///|
/// The same for the hash part, which shrinks while it is walked: the walk
/// restarts after each removal rather than trusting an index.  A tombstone
/// keeps its key, so a live slot is one with a value.
fn clear_values_of(st : LuaState, t : LTable) -> Unit {
  let mut again = true
  while again {
    again = false
    let n = t.hkeys.length()
    let mut i = 0
    while i < n {
      let v = t.hvals[i]
      if !v.is_nil() && gc_collectable(v) && !gc_reached(st, v) {
        t.hash_delete(t.hkeys[i])
        again = true
        break
      }
      i = i + 1
    }
  }
}

///|
/// Drops the entries a weak-key table can no longer keep, for the tables whose
/// mode is exactly `mode`.  This runs *after* the resurrecting pass, so a key
/// that a finalizable object still holds is kept.
fn clear_weak_keys(st : LuaState, mode : String) -> Unit {
  for t in st.weak_tables {
    if weak_mode_of(t) == mode {
      let mut again = true
      while again {
        again = false
        let n = t.hkeys.length()
        let mut i = 0
        while i < n {
          if !t.hvals[i].is_nil() {
            let gone = match t.hkeys[i] {
              KObj(k) => gc_collectable(k) && !gc_reached(st, k)
              _ => false
            }
            if gone {
              t.hash_delete(t.hkeys[i])
              again = true
              break
            }
          }
          i = i + 1
        }
      }
    }
  }
}

///|
/// One collection cycle.  Returns the objects whose `__gc` has to run, in the
/// order they should be called: the host layer runs them, because calling a Lua
/// function is not something this layer can do.
pub fn gc_collect(st : LuaState) -> Array[Value] {
  st.gc_epoch = st.gc_epoch + 1
  st.gc_marked = 0
  st.gc_marked_size = 0
  st.gc_counted_strings = Map([])
  let work : Array[Value] = []
  // The roots: the globals, the registry, an error handler a host may hold, and
  // the running thread.  Every other thread is reached through a value.
  mark(st, VTable(st.globals), work)
  mark(st, VTable(st.registry), work)
  mark(st, st.error_handler, work)
  mark(st, VThread(st.main_thread), work)
  mark(st, VThread(st.current_thread), work)
  drain(st, work)
  mark_ephemerons(st, work)
  // Values first, before anything is resurrected, then keys after: the
  // reference's `atomic` does exactly this, and the order is observable when
  // an object with a `__gc` is the only thing holding a weak key alive.
  clear_weak_values(st, "v")
  clear_weak_values(st, "kv")
  // Finalization, in two passes: first pick the unreachable objects that have a
  // `__gc` and keep their contents reachable while their handlers run, then let
  // the host call them, newest first, as the reference does.
  let pending : Array[Value] = []
  let kept : Array[Value] = []
  let mut i = st.finalizers.length()
  while i > 0 {
    i = i - 1
    let v = st.finalizers[i]
    if gc_collectable(v) && !gc_reached(st, v) {
      pending.push(v)
    } else {
      kept.push(v)
    }
  }
  st.finalizers = kept
  // The handlers may look at these objects, so what they hold stays alive --
  // and so does everything they reach, which is the resurrection a weak key
  // has to see.
  for v in pending {
    mark(st, v, work)
  }
  drain(st, work)
  mark_ephemerons(st, work)
  clear_weak_keys(st, "k")
  clear_weak_keys(st, "kv")
  clear_weak_values(st, "v")
  clear_weak_values(st, "kv")
  // What the live set holds once the cleared entries are gone is the figure the
  // next automatic collection is measured from.  The marking above ran before
  // the weak tables were cleared, so the size has to be taken again, and the
  // string clock along with it: everything created from here on is what the
  // count has not accounted for.
  st.memory_units = measure_live(st)
  st.gc_string_base = string_bytes_allocated()
  pending
}

///|
/// The bytes the live set occupies, measured by walking it.  Weak links are
/// followed as the collector follows them, so an entry a weak table has already
/// dropped is not counted -- the figure is taken after the clearing passes.
fn measure_live(st : LuaState) -> Int {
  st.gc_epoch = st.gc_epoch + 1
  st.gc_marked = 0
  st.gc_marked_size = 0
  st.gc_counted_strings = Map([])
  let work : Array[Value] = []
  mark(st, VTable(st.globals), work)
  mark(st, VTable(st.registry), work)
  mark(st, st.error_handler, work)
  mark(st, VThread(st.main_thread), work)
  mark(st, VThread(st.current_thread), work)
  drain(st, work)
  st.gc_marked_size
}

///|
/// What `collectgarbage("count")` reports, in bytes: the live size the last
/// cycle measured, plus everything allocated since.  A collection here is
/// atomic, so the second part is exactly the garbage that has not been looked
/// at yet -- which is what makes the count fall when a cycle runs.
pub fn live_size(st : LuaState) -> Int {
  st.memory_units + (string_bytes_allocated() - st.gc_string_base)
}
