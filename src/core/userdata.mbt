// Userdata, and the host file it carries.

///|
/// A host file.  `handle` is the C `FILE *`; 0 means the file is closed.
pub(all) struct LFile {
  mut handle : Int64
  mut closed : Bool
  standard : Bool
  popened : Bool
  name : String
}

///|
/// The kind of payload a userdata carries.
pub(all) enum UserDataKind {
  UDFile(LFile)
  /// The identity tag `debug.upvalueid` returns for an upvalue cell.
  UDUpvalTag(Int)
  /// The same, for a slot of a host function: such a function holds its
  /// upvalues as plain values rather than cells, so the tag is the pair that
  /// names the slot.
  UDCUpvalTag(Int, Int)
}

///|
/// A block of host data with an optional metatable and the user values
/// `debug.setuservalue` can reach.  A light one is only an identifier: it has
/// neither.
pub(all) struct LUserData {
  mut meta : LTable?
  kind : UserDataKind
  uservalues : Array[Value]
  id : Int
  light : Bool
  /// The collection cycle that last reached this userdata (see `LTable`).
  mut mark_epoch : Int
}

///|
pub fn LUserData::new_file(f : LFile) -> LUserData {
  charge_object_bytes(64)
  {
    meta: None,
    kind: UDFile(f),
    uservalues: [],
    id: next_object_id(),
    light: false,
    mark_epoch: 0,
  }
}

///|
/// The light userdata `debug.upvalueid` hands out to name an upvalue cell.
pub fn LUserData::new_light(k : UserDataKind) -> LUserData {
  {
    meta: None,
    kind: k,
    uservalues: [],
    id: next_object_id(),
    light: true,
    mark_epoch: 0,
  }
}

///|
pub fn Value::as_file(self : Value) -> LFile? {
  match self {
    VUserData(u) =>
      match u.kind {
        UDFile(f) => Some(f)
        UDUpvalTag(_) | UDCUpvalTag(_, _) => None
      }
    _ => None
  }
}

///|----------------------------------------------------------------
/// Interpreter results

///|----------------------------------------------------------------
