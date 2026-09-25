// `table.sort` and the quicksort of the reference implementation.

///|----------------------------------------------------------------
/// `table.sort`

///|----------------------------------------------------------------

///|
/// Elements are read and written through the metamethod-aware indexing of
/// `lua_geti`/`lua_seti`, so a table that only pretends to be one can be
/// sorted as well.
pub(all) struct SortState {
  state : @core.LuaState
  cmp : @core.Value
  table : @core.Value
}

///|
pub fn sort_less(
  ss : SortState,
  a : @core.Value,
  b : @core.Value,
) -> Bool raise @core.LuaRaised {
  if ss.cmp.is_nil() {
    @vm.less_than(ss.state, a, b)
  } else {
    let r = @vm.call_metamethod(ss.state, ss.cmp, [a, b], 1, "")
    if r.length() > 0 {
      r[0].is_truthy()
    } else {
      false
    }
  }
}

///|
fn sort_get(ss : SortState, i : Int64) -> @core.Value raise @core.LuaRaised {
  geti(ss.state, ss.table, i)
}

///|
fn sort_set(
  ss : SortState,
  i : Int64,
  v : @core.Value,
) -> Unit raise @core.LuaRaised {
  seti(ss.state, ss.table, i, v)
}

///|
fn invalid_order(state : @core.LuaState) -> Unit raise @core.LuaRaised {
  @core.runtime_error(state, "invalid order function for sorting")
}

///|
/// The sort of the reference implementation: quicksort over `lo .. up` with the
/// pivot parked in the slot below the top of the range, so both scans can lean
/// on it, and the tail call turned into a loop.
pub fn aux_sort(
  ss : SortState,
  lo0 : Int64,
  up0 : Int64,
) -> Unit raise @core.LuaRaised {
  let mut lo = lo0
  let mut up = up0
  let mut rnd = 0L
  let mut salt = 1UL
  while lo < up {
    let alo = sort_get(ss, lo)
    let aup = sort_get(ss, up)
    if sort_less(ss, aup, alo) {
      sort_set(ss, lo, aup)
      sort_set(ss, up, alo)
    }
    if up - lo == 1L {
      return
    }
    // The middle of a small interval is a good pivot; a large one could be
    // sorted against a fixed choice, so it gets a pseudo-random one.
    let p = if up - lo < 100L || rnd == 0L {
      (lo + up) / 2L
    } else {
      choose_pivot(lo, up, rnd)
    }
    let ap = sort_get(ss, p)
    let alo2 = sort_get(ss, lo)
    if sort_less(ss, ap, alo2) {
      sort_set(ss, p, alo2)
      sort_set(ss, lo, ap)
    } else {
      let aup2 = sort_get(ss, up)
      if sort_less(ss, aup2, ap) {
        sort_set(ss, p, aup2)
        sort_set(ss, up, ap)
      }
    }
    if up - lo == 2L {
      return
    }
    let pivot = sort_get(ss, p)
    let below = sort_get(ss, up - 1L)
    sort_set(ss, p, below)
    sort_set(ss, up - 1L, pivot)
    let q = partition(ss, lo, up, pivot)
    let lower_smaller = q - lo < up - q
    let n = if lower_smaller {
      aux_sort(ss, lo, q - 1L)
      q - lo
    } else {
      aux_sort(ss, q + 1L, up)
      up - q
    }
    if lower_smaller {
      lo = q + 1L
    } else {
      up = q - 1L
    }
    // A badly balanced partition is worth a new randomization.
    if (up - lo) / 128L > n {
      salt = (salt * 1103515245UL + 12345UL) % 4294967296UL
      rnd = salt.reinterpret_as_int64()
    }
  }
}

///|
/// Picks a pivot in the middle two quarters of `lo .. up`.
fn choose_pivot(lo : Int64, up : Int64, rnd : Int64) -> Int64 {
  let r4 = (up - lo) / 4L
  let span = r4 * 2L
  let p = if span > 0L {
    (rnd.reinterpret_as_uint64() % span.reinterpret_as_uint64()).reinterpret_as_int64()
  } else {
    0L
  }
  p + lo + r4
}

///|
/// Rearranges `lo .. up` around `pivot`, which sits at `up - 1`, and returns
/// where the pivot ends up.  A comparator that is not a strict weak order lets
/// a scan walk off the range, which is what the reference implementation
/// reports as an invalid order function.
fn partition(
  ss : SortState,
  lo : Int64,
  up : Int64,
  pivot : @core.Value,
) -> Int64 raise @core.LuaRaised {
  let mut i = lo
  let mut j = up - 1L
  for ;; {
    i = i + 1L
    while sort_less(ss, sort_get(ss, i), pivot) {
      // `a[i]` is below the pivot, yet that slot holds the pivot itself.
      if i == up - 1L {
        invalid_order(ss.state)
      }
      i = i + 1L
    }
    j = j - 1L
    while sort_less(ss, pivot, sort_get(ss, j)) {
      if j < i {
        invalid_order(ss.state)
      }
      j = j - 1L
    }
    if j < i {
      // Nothing is out of place: settle the pivot between the two parts.
      sort_set(ss, up - 1L, sort_get(ss, i))
      sort_set(ss, i, pivot)
      return i
    }
    let ai = sort_get(ss, i)
    let bj = sort_get(ss, j)
    sort_set(ss, i, bj)
    sort_set(ss, j, ai)
  }
}

///|
pub fn tbl_sort(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let t = checktab(
    state,
    args,
    1,
    "sort",
    index_of=true,
    newindex_of=true,
    length_of=true,
  )
  let n = objlen(state, t)
  if n > 1L {
    // The reference implementation indexes with an `unsigned int`.
    if n >= 2147483647L {
      @core.arg_error(state, 1, "sort", "array too big")
    }
    let cmp = if args.length() >= 2 && !args[1].is_nil() {
      @core.check_function(state, args, 2, "sort")
    } else {
      @core.VNil
    }
    let ss : SortState = { state, cmp, table: t, }
    aux_sort(ss, 1L, n)
  }
  @core.Nothing
}
