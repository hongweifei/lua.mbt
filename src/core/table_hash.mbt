// The hash part of a table, which is open addressed with linear probing.
//
// A slot holds a key and a value.  Clearing `t[k]` leaves the key in the slot
// and empties the value: the reference does the same, and it is what lets a
// traversal resumed with the key it has just deleted still find its slot.  Such
// a slot is nevertheless free -- it is where the next key that hashes past it
// goes -- so a search only ends at a slot that was never used at all.

///|
pub fn hash_slot(key : Key, mask : Int) -> Int {
  key_hash(key) & mask
}

///|
/// Walks the chain for `key`.  Returns the slot holding it, or -1, and the slot
/// a new key belonging to this chain should go in.  `for_next` asks for the key
/// of a cleared slot to count as found, which is what `next` needs; the value of
/// such a slot is nil, so it is never what a lookup should return.
fn LTable::probe(self : LTable, key : Key, for_next : Bool) -> (Int, Int) {
  let cap = self.hkeys.length()
  if cap == 0 {
    return (-1, -1)
  }
  let mask = cap - 1
  let mut i = hash_slot(key, mask)
  let mut insert = -1
  let mut probes = 0
  while probes <= mask {
    let k = self.hkeys[i]
    if k == KEmpty {
      return (-1, if insert >= 0 { insert } else { i })
    }
    if self.hvals[i].is_nil() {
      if k == key {
        if for_next {
          return (i, i)
        }
      }
      if insert < 0 {
        insert = i
      }
    } else if k == key {
      return (i, i)
    }
    i = (i + 1) & mask
    probes = probes + 1
  }
  (-1, insert)
}

///|
pub fn LTable::hash_find(self : LTable, key : Key) -> Int {
  self.probe(key, false).0
}

///|
/// The lookup `next` uses: a key whose value has been cleared is still a place
/// to continue from.
pub fn LTable::hash_find_key(self : LTable, key : Key) -> Int {
  self.probe(key, true).0
}

///|
pub fn LTable::hash_get(self : LTable, key : Key) -> Value {
  let i = self.hash_find(key)
  if i < 0 {
    VNil
  } else {
    self.hvals[i]
  }
}

///|
/// Inserts into a table that is known to have a free slot.  Used by the rehash
/// path, which must not recurse back into the growth check.
pub fn LTable::hash_put(self : LTable, key : Key, value : Value) -> Unit {
  let (found, insert) = self.probe(key, false)
  if found >= 0 {
    self.hvals[found] = value
    return
  }
  if insert < 0 {
    return
  }
  // Reusing a slot that still holds the key of a cleared entry gives back the
  // space that entry was holding.
  if self.hkeys[insert] != KEmpty {
    self.hdead = self.hdead - 1
  }
  self.hkeys[insert] = key
  self.hvals[insert] = value
  self.hlive = self.hlive + 1
}

///|
/// Rebuilds the hash part with a capacity that leaves at least a quarter of the
/// slots free.  Cleared slots are dropped, which is why a traversal must not
/// hold on to a key across a growth of the table.
pub fn LTable::hash_rehash(self : LTable, min_cap : Int) -> Unit {
  let mut cap = 4
  while cap < min_cap {
    cap = cap * 2
  }
  while (self.hlive + 1) * 4 >= cap * 3 {
    cap = cap * 2
  }
  let old_keys = self.hkeys
  let old_vals = self.hvals
  self.hkeys = Array::make(cap, KEmpty)
  self.hvals = Array::make(cap, VNil)
  self.hlive = 0
  self.hdead = 0
  let n = old_keys.length()
  let mut i = 0
  while i < n {
    if !old_vals[i].is_nil() {
      self.hash_put(old_keys[i], old_vals[i])
    }
    i = i + 1
  }
}

///|
pub fn LTable::hash_set(self : LTable, key : Key, value : Value) -> Unit {
  if self.hkeys.length() == 0 {
    self.hash_rehash(4)
  }
  let i = self.hash_find(key)
  if i >= 0 {
    self.hvals[i] = value
    return
  }
  if (self.hlive + self.hdead + 1) * 4 >= self.hkeys.length() * 3 {
    self.hash_rehash(4)
  }
  self.hash_put(key, value)
}

///|
/// Clears the value of `key`, keeping its key in place so that a traversal can
/// still be resumed with it.  The slot is not reclaimed here: the reference only
/// rebuilds the hash part when it grows, and a traversal that deletes the key it
/// is on relies on the key staying where it was.
pub fn LTable::hash_delete(self : LTable, key : Key) -> Unit {
  let i = self.hash_find(key)
  if i >= 0 {
    self.hvals[i] = VNil
    self.hlive = self.hlive - 1
    self.hdead = self.hdead + 1
  }
}

///|----------------------------------------------------------------
/// Array part

///|----------------------------------------------------------------
