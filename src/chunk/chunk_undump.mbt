// Reading a binary chunk back.

///|
pub(all) struct BinReader {
  data : Bytes
  mut pos : Int
  mut failed : Bool
}

///|
/// Whether a chunk is precompiled rather than source: its first byte is the
/// signature's, and nothing else is looked at, so a chunk truncated to a single
/// byte is still a binary chunk -- and is then reported as truncated.
pub fn is_binary_chunk(data : Bytes) -> Bool {
  data.length() > 0 && @core.ubyte_at(data, 0) == 0x1b
}

///|
/// The name a chunk that failed to load is reported under: a leading `@` or `=`
/// introduces the name rather than being part of it, and a chunk named after its
/// own bytes -- which is what `load` does when given no name -- is a binary
/// string.
fn load_name(name : String) -> String {
  if name == "" {
    ""
  } else {
    let c = name[0]
    if c == '@' || c == '=' {
      name[1:].to_owned()
    } else if c.to_int() == 0x1b {
      "binary string"
    } else {
      name
    }
  }
}

///|
/// Reads and validates the header, giving back the reason it was refused.  The
/// first byte of the signature has already been seen.
fn check_header(r : BinReader) -> String? {
  let mut i = 1
  while i < chunk_signature.length() {
    if r.u8() != @core.ubyte_at(chunk_signature, i) {
      return Some("not a binary chunk")
    }
    i = i + 1
  }
  if r.u8() != CHUNK_VERSION {
    return Some("version mismatch")
  }
  if r.u8() != CHUNK_FORMAT {
    return Some("format mismatch")
  }
  let mut j = 0
  while j < chunk_data.length() {
    if r.u8() != @core.ubyte_at(chunk_data, j) {
      return Some("corrupted chunk")
    }
    j = j + 1
  }
  if r.u8() != SIZEOF_INSTRUCTION {
    return Some("Instruction size mismatch")
  }
  if r.u8() != SIZEOF_INTEGER {
    return Some("lua_Integer size mismatch")
  }
  if r.u8() != SIZEOF_NUMBER {
    return Some("lua_Number size mismatch")
  }
  if r.i64() != LUAC_INT {
    return Some("integer format mismatch")
  }
  if r.f64() != LUAC_NUM {
    return Some("float format mismatch")
  }
  None
}

///|
/// The diagnostic for a chunk that is not one this loader can read.
fn bad_format(name : String, why : String) -> @core.LoadOutcome {
  @core.LoadError(
    @core.bytes_of(load_name(name) + ": bad binary format (" + why + ")"),
  )
}

///|
/// Loads a binary chunk.  Upvalue 0 receives the environment, exactly like
/// loading source text; the remaining upvalues start as nil.
pub fn undump(
  _state : @core.LuaState,
  data : Bytes,
  env : @core.Value,
  name : String,
) -> @core.LoadOutcome {
  let r = BinReader::new(data)
  r.pos = 1
  match check_header(r) {
    Some(why) =>
      return bad_format(name, if r.failed { "truncated chunk" } else { why })
    None => ()
  }
  let proto = r.proto(@core.no_source())
  if r.failed {
    return bad_format(name, "truncated chunk")
  }
  let upvals : Array[@core.LUpval] = []
  let mut i = 0
  while i < proto.upvals.length() {
    if i == 0 {
      upvals.push(@core.LUpval::new_closed(env))
    } else {
      upvals.push(@core.LUpval::new_closed(@core.VNil))
    }
    i = i + 1
  }
  let cl : @core.LClosure = {
    proto,
    upvals,
    id: @core.next_object_id(),
    mark_epoch: 0,
  }
  @core.LoadOk(@core.VFunc(cl))
}
