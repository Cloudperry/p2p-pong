import std/[net, streams]

type
  SocketStream* = ref SocketStreamObj
  SocketStreamObj* = object of Stream
    socket*: Socket
    eofReached: bool

proc ssClose(s: Stream) =
  let ss = SocketStream(s)
  if ss.socket != nil:
    ss.socket.close()
    ss.socket = nil

proc ssAtEnd(s: Stream): bool =
  let ss = SocketStream(s)
  return ss.eofReached

proc ssReadData(s: Stream, buffer: pointer, bufLen: int): int =
  let ss = SocketStream(s)
  var totalRead = 0
  let dest = cast[ptr UncheckedArray[byte]](buffer)
  while totalRead < bufLen:
    let n = ss.socket.recv(addr dest[totalRead], bufLen - totalRead)
    if n <= 0:
      ss.eofReached = true
      break
    totalRead += n
  return totalRead

proc ssWriteData(s: Stream, buffer: pointer, bufLen: int) =
  let ss = SocketStream(s)
  var totalSent = 0
  let src = cast[ptr UncheckedArray[byte]](buffer)
  while totalSent < bufLen:
    let n = ss.socket.send(addr src[totalSent], bufLen - totalSent)
    if n <= 0:
      ss.eofReached = true
      break
    totalSent += n

proc ssFlush(s: Stream) =
  discard

proc newSocketStream*(socket: Socket): SocketStream =
  new(result)
  result.socket = socket
  result.eofReached = false
  result.closeImpl = ssClose
  result.atEndImpl = ssAtEnd
  result.readDataImpl = ssReadData
  result.writeDataImpl = ssWriteData
  result.flushImpl = ssFlush
