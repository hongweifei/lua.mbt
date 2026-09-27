// The prefix a chunk read from a file may carry: a UTF-8 byte order mark and a
// first line starting with `#`.  Both are dropped by `luaL_loadfilex`, and the
// dropped line is replaced by a newline so that line numbers do not move.

///|
/// The result as text, with the newline made visible, so that the tests read
/// like the bytes they are about.  Only for results that are ASCII.
fn show(b : Bytes) -> String {
  @core.text_of(b).replace_all(old="\n", new="\\n")
}

///|
test "a chunk with no prefix is handed on unchanged" {
  assert_eq(show(@load.strip_chunk_prefix(b"return 1\n")), "return 1\\n")
  // A `#` anywhere but the first byte is the length operator, not a comment.
  assert_eq(show(@load.strip_chunk_prefix(b"x = #t\n")), "x = #t\\n")
}

///|
test "a byte order mark is dropped" {
  assert_eq(
    show(@load.strip_chunk_prefix(b"\xEF\xBB\xBFreturn 1\n")),
    "return 1\\n",
  )
  // Nothing but a mark is an empty chunk.
  assert_true(@load.strip_chunk_prefix(b"\xEF\xBB\xBF") == b"")
  // Only a whole mark counts: a lone 0xEF is left where it is, so that the
  // lexer refuses it -- which is what the reference's `skipBOM` leaves too.
  assert_true(@load.strip_chunk_prefix(b"\xEFreturn 1") == b"\xEFreturn 1")
  assert_true(
    @load.strip_chunk_prefix(b"\xEF\xBBreturn 1") == b"\xEF\xBBreturn 1",
  )
}

///|
test "a first line starting with # is replaced by its newline" {
  assert_eq(
    show(@load.strip_chunk_prefix(b"#!/usr/bin/lua\nreturn 2\n")),
    "\\nreturn 2\\n",
  )
  // A mark in front of the line does not hide it.
  assert_eq(
    show(@load.strip_chunk_prefix(b"\xEF\xBB\xBF# a comment\nreturn 3\n")),
    "\\nreturn 3\\n",
  )
  // The line may run to the end of the file, with or without a newline: what is
  // left is the newline that stands for it.
  assert_true(@load.strip_chunk_prefix(b"# no newline here") == b"\n")
  assert_true(@load.strip_chunk_prefix(b"#") == b"\n")
}
