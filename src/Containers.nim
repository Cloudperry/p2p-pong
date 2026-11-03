## A fixed-size ring buffer. Once it fills up, `i` wraps back to the start and
## old values get overwritten. Used for storing the last N frame times and replay actions.
type CircularBuffer*[N: Natural, T] = object
  data*: array[N, T]
  i*: Natural = 0 # TODO: Rename this to something less confusing

proc push*[N, T](b: var CircularBuffer[N, T], v: T) =
  ## Writes a value at the current index and advances it, wrapping around at the end.
  b.data[b.i] = v
  b.i += 1
  b.i = b.i mod b.data.len

iterator range*[N, T](b: CircularBuffer[N, T], iStart, iEnd: Natural): T =
  ## Yields values from iStart to iEnd (inclusive), wrapping around the end of the buffer.
  var i = iStart
  while true:
    yield b.data[i]
    if i == iEnd:
      break

    i += 1
    i = i mod b.data.len
