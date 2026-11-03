import std/[net, nativesockets, strformat, tables]
import pkg/[raylib, confutils, glm]
import ./[Input, NetworkStream]

const
  screenWidth* = 800
  screenHeight* = 600
  paddleWidth* = 15.0
  paddleHeight* = 100.0
  paddleSpeed* = 400.0
  paddleMargin* = 30.0
  ballRadius* = 10.0
  initialBallSpeedX* = 350.0
  initialBallSpeedY* = 220.0
  fixedDeltaTime* = 1.0 / 60.0

type
  Config* = object
    host* {.
      name: "host",
      defaultValue: false,
      desc: "Run as host (Player 1, left paddle) and wait for a client connection"
    .}: bool
    connectIp* {.
      name: "connect",
      defaultValue: "",
      desc: "Connect to host IP as client (Player 2, right paddle)"
    .}: string
    port* {.
      name: "port",
      defaultValue: 7777,
      desc: "TCP port to listen on or connect to"
    .}: int
    recordReplay* {.
      name: "recordReplay",
      defaultValue: "",
      desc: "Optional replay name to record the match to disk"
    .}: string
    playReplay* {.
      name: "playReplay",
      defaultValue: "",
      desc: "Optional replay name to play back from disk without networking"
    .}: string

  ActionNames* = enum
    NoopTick
    P1MoveUp
    P1MoveDown
    P2MoveUp
    P2MoveDown
    SetDeltaTime

  PongGame* = ref object
    p1Y*, p2Y*: float
    p1MoveDir*, p2MoveDir*: float
    ballPos*: Vec2f
    ballVel*: Vec2f
    score1*, score2*: int
    deltaTime*: float
    tickN*: uint64

proc resetBall*(game: PongGame, dirX: float) =
  game.ballPos = vec2f(screenWidth / 2.0, screenHeight / 2.0)
  game.ballVel = vec2f(initialBallSpeedX * dirX, initialBallSpeedY)

proc initPongGame*(): PongGame =
  result = PongGame(
    p1Y: (screenHeight - paddleHeight) / 2.0,
    p2Y: (screenHeight - paddleHeight) / 2.0,
    deltaTime: fixedDeltaTime,
  )
  result.resetBall(1.0)

proc makeActions*(game: PongGame): Actions[ActionNames] =
  {
    NoopTick: initBoolAction(
      proc(active: bool) =
        discard,
      runOnlyWhenNonZero = false,
    ),
    P1MoveUp: initBoolAction(
      proc(active: bool) =
        game.p1MoveDir -= 1.0
    ),
    P1MoveDown: initBoolAction(
      proc(active: bool) =
        game.p1MoveDir += 1.0
    ),
    P2MoveUp: initBoolAction(
      proc(active: bool) =
        game.p2MoveDir -= 1.0
    ),
    P2MoveDown: initBoolAction(
      proc(active: bool) =
        game.p2MoveDir += 1.0
    ),
    SetDeltaTime: initFloatAction(
      proc(dt: float) =
        game.deltaTime = dt,
      runOnlyWhenNonZero = false,
    ),
  }.toTable

proc updateSimulation*(game: PongGame) =
  let dt = game.deltaTime

  # Update paddles
  game.p1Y = clamp(
    game.p1Y + game.p1MoveDir * paddleSpeed * dt,
    0.0,
    screenHeight.float - paddleHeight,
  )
  game.p2Y = clamp(
    game.p2Y + game.p2MoveDir * paddleSpeed * dt,
    0.0,
    screenHeight.float - paddleHeight,
  )

  # Update ball position
  game.ballPos.x += game.ballVel.x * dt
  game.ballPos.y += game.ballVel.y * dt

  # Top and bottom wall collisions
  if game.ballPos.y - ballRadius <= 0.0 and game.ballVel.y < 0.0:
    game.ballPos.y = ballRadius
    game.ballVel.y = -game.ballVel.y
  elif game.ballPos.y + ballRadius >= screenHeight.float and game.ballVel.y > 0.0:
    game.ballPos.y = screenHeight.float - ballRadius
    game.ballVel.y = -game.ballVel.y

  # Left paddle (P1) collision
  let p1Right = paddleMargin + paddleWidth
  if game.ballVel.x < 0.0 and
      game.ballPos.x - ballRadius <= p1Right and
      game.ballPos.x + ballRadius >= paddleMargin and
      game.ballPos.y + ballRadius >= game.p1Y and
      game.ballPos.y - ballRadius <= game.p1Y + paddleHeight:
    game.ballPos.x = p1Right + ballRadius
    game.ballVel.x = -game.ballVel.x
    let hitOffset =
      ((game.ballPos.y - (game.p1Y + paddleHeight / 2.0)) / (paddleHeight / 2.0))
    game.ballVel.y = hitOffset * initialBallSpeedY * 1.5

  # Right paddle (P2) collision
  let p2Left = screenWidth.float - paddleMargin - paddleWidth
  if game.ballVel.x > 0.0 and
      game.ballPos.x + ballRadius >= p2Left and
      game.ballPos.x - ballRadius <= p2Left + paddleWidth and
      game.ballPos.y + ballRadius >= game.p2Y and
      game.ballPos.y - ballRadius <= game.p2Y + paddleHeight:
    game.ballPos.x = p2Left - ballRadius
    game.ballVel.x = -game.ballVel.x
    let hitOffset =
      ((game.ballPos.y - (game.p2Y + paddleHeight / 2.0)) / (paddleHeight / 2.0))
    game.ballVel.y = hitOffset * initialBallSpeedY * 1.5

  # Scoring
  if game.ballPos.x + ballRadius < 0.0:
    game.score2 += 1
    game.resetBall(1.0)
  elif game.ballPos.x - ballRadius > screenWidth.float:
    game.score1 += 1
    game.resetBall(-1.0)

  game.tickN += 1

proc drawGame*(game: PongGame) =
  clearBackground(Black)

  # Center dashed line
  for y in countup(0, screenHeight, 30):
    drawRectangle(
      int32(screenWidth div 2 - 2), int32(y), 4, 15, DarkGray
    )

  # Scores
  let s1Text = $game.score1
  let s2Text = $game.score2
  drawText(
    s1Text,
    int32(screenWidth div 4 - measureText(s1Text, 40) div 2),
    30,
    40,
    RayWhite,
  )
  drawText(
    s2Text,
    int32((screenWidth * 3) div 4 - measureText(s2Text, 40) div 2),
    30,
    40,
    RayWhite,
  )

  # Paddles
  drawRectangle(
    int32(paddleMargin),
    int32(game.p1Y),
    int32(paddleWidth),
    int32(paddleHeight),
    RayWhite,
  )
  drawRectangle(
    int32(screenWidth.float - paddleMargin - paddleWidth),
    int32(game.p2Y),
    int32(paddleWidth),
    int32(paddleHeight),
    RayWhite,
  )

  # Ball
  drawCircle(
    Vector2(x: game.ballPos.x, y: game.ballPos.y),
    float32(ballRadius),
    RayWhite,
  )

proc setupNetwork(conf: Config): Socket =
  if conf.host:
    var server = newSocket()
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(conf.port))
    server.listen()
    echo fmt"Waiting for Player 2 to connect on port {conf.port}..."
    var client: Socket
    var address = ""
    server.acceptAddr(client, address)
    echo fmt"Player 2 connected from {address}"
    server.close()
    client.getFd().setBlocking(true)
    return client
  elif conf.connectIp.len > 0:
    var sock = newSocket()
    echo fmt"Connecting to host {conf.connectIp}:{conf.port}..."
    sock.connect(conf.connectIp, Port(conf.port))
    echo "Connected to host!"
    sock.getFd().setBlocking(true)
    return sock
  else:
    quit "Please specify either --host or --connect=<ip> (or --playReplay=<name>)"

const
  p1KeyBindings*: InputsToActions[ActionNames, KeyboardKey] = {
    KeyboardKey.Comma: P1MoveUp,
    KeyboardKey.W: P1MoveUp,
    KeyboardKey.Up: P1MoveUp,
    KeyboardKey.O: P1MoveDown,
    KeyboardKey.S: P1MoveDown,
    KeyboardKey.Down: P1MoveDown,
  }.toTable

  p2KeyBindings*: InputsToActions[ActionNames, KeyboardKey] = {
    KeyboardKey.Comma: P2MoveUp,
    KeyboardKey.W: P2MoveUp,
    KeyboardKey.Up: P2MoveUp,
    KeyboardKey.O: P2MoveDown,
    KeyboardKey.S: P2MoveDown,
    KeyboardKey.Down: P2MoveDown,
  }.toTable

when isMainModule:
  let conf = Config.load()
  var game = initPongGame()
  let actions = game.makeActions()

  if conf.playReplay.len > 0:
    var filePlayer = initReplayPlayer[ActionNames](conf.playReplay, actions)
    initWindow(screenWidth, screenHeight, "Pong - Replay")
    setTargetFPS(60)
    while not windowShouldClose():
      game.p1MoveDir = 0.0
      game.p2MoveDir = 0.0
      let res = filePlayer.play(game.tickN)
      if res.replayEnded:
        break
      game.updateSimulation()
      beginDrawing()
      game.drawGame()
      endDrawing()
    filePlayer.deinit()
    closeWindow()
  else:
    let netSocket = setupNetwork(conf)
    let sendStream = newSocketStream(netSocket)
    let recvStream = newSocketStream(netSocket)

    var localRecorder = initStreamReplayRecorder[ActionNames](sendStream, actions)
    var remotePlayer = initStreamReplayPlayer[ActionNames](recvStream, actions)

    let recordingToFile = conf.recordReplay.len > 0
    var fileRecorder: ReplaySystem[ActionNames]
    if recordingToFile:
      fileRecorder = initReplayRecorder[ActionNames](conf.recordReplay, actions)

    let isHost = conf.host
    let localBindings = if isHost: p1KeyBindings else: p2KeyBindings
    let winTitle = if isHost: "Pong - Player 1 (Host)" else: "Pong - Player 2 (Client)"

    initWindow(screenWidth, screenHeight, winTitle)
    setTargetFPS(60)

    while not windowShouldClose():
      game.p1MoveDir = 0.0
      game.p2MoveDir = 0.0

      # Always record a tick marker so every tick is represented in the replay buffer
      localRecorder.recordFrameData(NoopTick, game.tickN, true, true)
      if isHost:
        game.deltaTime = fixedDeltaTime
        localRecorder.recordFrameData(SetDeltaTime, game.tickN, game.deltaTime, true)

      # Read local player inputs and record them into the outgoing replay buffer
      localRecorder.addRecordingInputReader(
        localBindings,
        proc(k: KeyboardKey): bool =
          isKeyDown(k),
        game.tickN,
        game.deltaTime,
        true,
      )

      if recordingToFile:
        for i in 0 ..< localRecorder.buf.i:
          fileRecorder.recordActionAndFlushToFile(localRecorder.buf.data[i])

      # Flush local replay buffer over the network socket
      localRecorder.flush()

      # Receive and play remote player's replay buffer for this tick
      let playback = remotePlayer.play(game.tickN)
      if playback.replayEnded:
        echo "Peer disconnected."
        break

      if recordingToFile:
        for act in playback.playedActions:
          fileRecorder.recordActionAndFlushToFile(act)

      game.updateSimulation()

      beginDrawing()
      game.drawGame()
      endDrawing()

    if recordingToFile:
      fileRecorder.deinit()
    netSocket.close()
    closeWindow()
