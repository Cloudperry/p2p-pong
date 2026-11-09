## A fixed-size ring buffer. Once it fills up, `writeIndex` wraps back to the start and
## old values get overwritten. Used for storing the last N frame times and replay actions.
type CircularBuffer*[N: Natural, T] = object
  data*: array[N, T]
  writeIndex*: Natural = 0

proc push*[N, T](buffer: var CircularBuffer[N, T], value: T) =
  ## Writes a value at the current index and advances it, wrapping around at the end.
  buffer.data[buffer.writeIndex] = value
  buffer.writeIndex = (buffer.writeIndex + 1) mod buffer.data.len

iterator range*[N, T](buffer: CircularBuffer[N, T], startIndex, endIndex: Natural): T =
  ## Yields values from startIndex to endIndex (inclusive), wrapping around the end of the buffer.
  var index = startIndex
  while true:
    yield buffer.data[index]
    if index == endIndex:
      break

    index = (index + 1) mod buffer.data.len
