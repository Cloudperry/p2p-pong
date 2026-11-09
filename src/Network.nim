import std/[math, net, strformat]
import pkg/flatty
import ./Input

const
  minTargetFps* = 30
  maxTargetFps* = 600
  defaultTargetFps* = 60
  maxUdpPacketBytes = 8192

type
  MessageKind* = enum
    ClientHello
    SessionConfig
    ReplayUpdate
    Disconnect

  NetworkMessage*[A: enum] = object
    case kind*: MessageKind
    of ClientHello, Disconnect:
      discard
    of SessionConfig:
      fixedFrameTime*: float
    of ReplayUpdate:
      chunk*: ReplayChunk[A]

  NetworkSession*[A: enum] = object
    socket*: Socket
    peerIp*: IpAddress
    peerPort*: Port
    fixedFrameTime*: float

proc formatEndpoint(ip: IpAddress, port: Port): string =
  fmt"{ip}:{port.int}"

proc targetFps*[A: enum](session: NetworkSession[A]): int =
  ## Converts the session's negotiated fixed frame time (seconds) to integer FPS.
  round(1 / session.fixedFrameTime).int

proc validateTargetFps*(fps: int) =
  if fps notin minTargetFps .. maxTargetFps:
    raise newException(
      ValueError,
      fmt"Framerate must be between {minTargetFps} and {maxTargetFps} FPS (got {fps})",
    )

proc newUdpSocket*(): Socket =
  newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, buffered = false)

proc close*[A: enum](session: NetworkSession[A]) =
  if session.socket != nil:
    session.socket.close()

proc send*[A: enum](session: NetworkSession[A], message: NetworkMessage[A]) =
  session.socket.sendTo(session.peerIp, session.peerPort, toFlatty(message))

proc sendReplay*[A: enum](session: NetworkSession[A], chunk: ReplayChunk[A]) =
  session.send(NetworkMessage[A](kind: ReplayUpdate, chunk: chunk))

proc sendDisconnect*[A: enum](session: NetworkSession[A]) =
  session.send(NetworkMessage[A](kind: Disconnect))

proc receivePacket[A: enum](
    socket: Socket
): tuple[message: NetworkMessage[A], senderIp: IpAddress, senderPort: Port] =
  var payload = ""
  discard socket.recvFrom(payload, maxUdpPacketBytes, result.senderIp, result.senderPort)
  result.message = payload.fromFlatty(NetworkMessage[A])

proc receive*[A: enum](session: NetworkSession[A]): NetworkMessage[A] =
  receivePacket[A](session.socket).message

proc acceptSession*[A: enum](
    hostSocket: Socket, actionType: typedesc[A], fps = defaultTargetFps
): NetworkSession[A] =
  ## Completes the host side of the UDP handshake on an already-bound socket.
  validateTargetFps(fps)
  let (hello, clientIp, clientPort) = receivePacket[A](hostSocket)
  doAssert hello.kind == ClientHello, "Expected ClientHello from connecting peer"

  result = NetworkSession[A](
    socket: hostSocket,
    peerIp: clientIp,
    peerPort: clientPort,
    fixedFrameTime: 1 / fps,
  )
  result.send(NetworkMessage[A](kind: SessionConfig, fixedFrameTime: result.fixedFrameTime))

proc hostSession*[A: enum](
    actionType: typedesc[A], port: int, fps = defaultTargetFps
): NetworkSession[A] =
  ## Binds a UDP socket on `port`, waits for a client, and negotiates `fixedFrameTime`.
  validateTargetFps(fps)
  let socket = newUdpSocket()
  socket.bindAddr(Port(port))
  echo fmt"Waiting for Player 2 on UDP port {port} ({fps} FPS)..."
  result = socket.acceptSession(A, fps)
  let endpoint = formatEndpoint(result.peerIp, result.peerPort)
  echo fmt"Player 2 connected from {endpoint}"

proc sendClientHello*[A: enum](
    clientSocket: Socket, actionType: typedesc[A], hostAddress: string, port: int
) =
  clientSocket.sendTo(
    hostAddress, Port(port), toFlatty(NetworkMessage[A](kind: ClientHello))
  )

proc completeClientHandshake*[A: enum](
    clientSocket: Socket, actionType: typedesc[A]
): NetworkSession[A] =
  let (configMessage, hostIp, hostPort) = receivePacket[A](clientSocket)
  doAssert configMessage.kind == SessionConfig, "Expected SessionConfig from host"
  NetworkSession[A](
    socket: clientSocket,
    peerIp: hostIp,
    peerPort: hostPort,
    fixedFrameTime: configMessage.fixedFrameTime,
  )

proc joinSession*[A: enum](
    actionType: typedesc[A], hostAddress: string, port: int
): NetworkSession[A] =
  ## Connects to a UDP host and receives the negotiated `fixedFrameTime`.
  let socket = newUdpSocket()
  echo fmt"Connecting to host {hostAddress}:{port}..."
  socket.sendClientHello(A, hostAddress, port)
  result = socket.completeClientHandshake(A)
  let negotiatedFps = result.targetFps
  echo fmt"Connected to host! Negotiated {negotiatedFps} FPS"
