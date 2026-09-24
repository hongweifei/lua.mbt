// The result of loading a chunk: either a callable value or an error.

///|
pub(all) enum LoadOutcome {
  LoadOk(Value)
  LoadError(Bytes)
}
