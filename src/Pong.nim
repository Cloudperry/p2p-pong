import std/[strformat, tables]
import pkg/[confutils, vmath]
import ./[Input, Network, RaylibConverters]

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

type
  Config* = object
    host* {.
      name: "host",
      defaultValue: false,
      desc: "Run as host (Player 1, left paddle) and wait for a client"
    .}: bool
    connectIp* {.
      name: "connect",
      defaultValue: "",
      desc: "Connect to host IP as client (Player 2, right paddle)"
    .}: string
    port* {.
      name: "port",
      defaultValue: 7777,
      desc: "UDP port to listen on or connect to"
    .}: int
    fps* {.
      name: "fps",
      defaultValue: defaultTargetFps,
      desc: "Target framerate set by the host (30..600 FPS)"
    .}: int

  Circle* = object
    pos*: Vec2
    radius*: float

  Rect* = object
    pos*: Vec2
    size*: Vec2

  PlayerId* = enum
    Player1
    Player2

  ActionNames* = enum
    Player1MoveUp
    Player1MoveDown
    Player2MoveUp
    Player2MoveDown

  Player* = object
    paddle*: Rect
    moveDirection*: float
    score*: int

  PongGame* = ref object
    players*: array[PlayerId, Player]
    ball*: Circle
    ballVelocity*: Vec2
    deltaTime*: float
    tick*: int

const
  screenBounds* = Rect(pos: vec2(0, 0), size: vec2(screenWidth, screenHeight))
  paddleSize = vec2(paddleWidth, paddleHeight)
  paddleX: array[PlayerId, float] = [
    Player1: paddleMargin,
    Player2: screenWidth - paddleMargin - paddleWidth,
  ]
  bounceDirectionX: array[PlayerId, float] = [Player1: 1.0, Player2: -1.0]
  paddleBounceX: array[PlayerId, float] = [
    Player1: paddleX[Player1] + paddleWidth + ballRadius,
    Player2: paddleX[Player2] - ballRadius,
  ]
  scoreCenterX: array[PlayerId, int] = [
    Player1: screenWidth div 4,
    Player2: (screenWidth * 3) div 4,
  ]
  windowTitles: array[PlayerId, string] = [
    Player1: "Pong - Player 1 (Host)",
    Player2: "Pong - Player 2 (Client)",
  ]

proc overlaps*(circle: Circle, rect: Rect): bool =
  ## Returns true if `circle` overlaps `rect`.
  let closest = vec2(
    clamp(circle.pos.x, rect.pos.x, rect.pos.x + rect.size.x),
    clamp(circle.pos.y, rect.pos.y, rect.pos.y + rect.size.y),
  )
  dist(circle.pos, closest) < circle.radius

proc outsideVerticalBounds*(circle: Circle, bounds: Rect): bool =
  ## Returns true if `circle` extends past the top or bottom edge of `bounds`.
  circle.pos.y - circle.radius < bounds.pos.y or
    circle.pos.y + circle.radius > bounds.pos.y + bounds.size.y

proc resetBall*(game: PongGame, directionX: float) =
  game.ball = Circle(pos: vec2(screenWidth / 2, screenHeight / 2), radius: ballRadius)
  game.ballVelocity = vec2(initialBallSpeedX * directionX, initialBallSpeedY)

proc initPongGame*(deltaTime = 1 / defaultTargetFps): PongGame =
  let startY = (screenHeight - paddleHeight) / 2
  result = PongGame(deltaTime: deltaTime)
  for id in PlayerId:
    result.players[id].paddle = Rect(pos: vec2(paddleX[id], startY), size: paddleSize)
  result.resetBall(1)

proc resetMoveDirections*(game: PongGame) =
  for id in PlayerId:
    game.players[id].moveDirection = 0

proc makeActions*(game: PongGame): Actions[ActionNames] =
  proc moveAction(id: PlayerId, step: float): Action =
    initBoolAction(proc(active: bool) = game.players[id].moveDirection += step)

  {
    Player1MoveUp: moveAction(Player1, -1),
    Player1MoveDown: moveAction(Player1, 1),
    Player2MoveUp: moveAction(Player2, -1),
    Player2MoveDown: moveAction(Player2, 1),
  }.toTable

proc updateSimulation*(game: PongGame) =
  for id in PlayerId:
    let nextY =
      game.players[id].paddle.pos.y +
      game.players[id].moveDirection * paddleSpeed * game.deltaTime
    game.players[id].paddle.pos.y = clamp(nextY, 0.0, screenHeight - paddleHeight)

  game.ball.pos += game.ballVelocity * game.deltaTime

  if game.ball.outsideVerticalBounds(screenBounds):
    game.ball.pos.y = clamp(game.ball.pos.y, ballRadius, screenHeight - ballRadius)
    game.ballVelocity.y = -game.ballVelocity.y

  for id in PlayerId:
    let paddle = game.players[id].paddle
    if game.ball.overlaps(paddle) and game.ballVelocity.x * bounceDirectionX[id] < 0:
      game.ball.pos.x = paddleBounceX[id]
      game.ballVelocity.x = -game.ballVelocity.x
      let paddleCenterY = paddle.pos.y + paddle.size.y / 2
      let hitOffset = (game.ball.pos.y - paddleCenterY) / (paddle.size.y / 2)
      game.ballVelocity.y = hitOffset * initialBallSpeedY * 1.5

  if game.ball.pos.x + ballRadius < 0:
    game.players[Player2].score += 1
    game.resetBall(1)
  elif game.ball.pos.x - ballRadius > screenWidth:
    game.players[Player1].score += 1
    game.resetBall(-1)

  game.tick += 1

proc drawGame*(game: PongGame) =
  clearBackground(Black)

  for y in countup(0, screenHeight, 30):
    drawRectangle(screenWidth div 2 - 2, y, 4, 15, DarkGray)

  for id, player in game.players:
    let scoreText = $player.score
    let scoreX = scoreCenterX[id] - measureText(scoreText, 40) div 2
    drawText(scoreText, scoreX, 30, 40, RayWhite)
    drawRectangle(player.paddle.pos, player.paddle.size, RayWhite)

  drawCircle(game.ball.pos, game.ball.radius, RayWhite)

proc makeKeyBindings(
    moveUp, moveDown: ActionNames
): InputsToActions[ActionNames, KeyboardKey] =
  {
    KeyboardKey.Comma: moveUp,
    KeyboardKey.W: moveUp,
    KeyboardKey.Up: moveUp,
    KeyboardKey.O: moveDown,
    KeyboardKey.S: moveDown,
    KeyboardKey.Down: moveDown,
  }.toTable

const keyBindings*: array[PlayerId, InputsToActions[ActionNames, KeyboardKey]] = [
  Player1: makeKeyBindings(Player1MoveUp, Player1MoveDown),
  Player2: makeKeyBindings(Player2MoveUp, Player2MoveDown),
]

proc setupNetwork(config: Config): NetworkSession[ActionNames] =
  if config.host:
    if config.fps notin minTargetFps .. maxTargetFps:
      quit fmt"Framerate must be between {minTargetFps} and {maxTargetFps} FPS"
    return hostSession(ActionNames, config.port, config.fps)
  elif config.connectIp.len > 0:
    return joinSession(ActionNames, config.connectIp, config.port)
  else:
    quit "Please specify either --host or --connect=<ip>"

proc main() =
  let config = Config.load()
  let session = setupNetwork(config)
  defer:
    session.close()

  var game = initPongGame(session.fixedFrameTime)
  let actions = game.makeActions()
  var localRecorder = initReplayRecorder(actions)
  var remotePlayer = initReplayPlayer(actions)

  let localPlayer = if config.host: Player1 else: Player2
  initWindow(screenWidth, screenHeight, windowTitles[localPlayer])
  defer:
    closeWindow()
  setTargetFPS(session.targetFps)

  var peerDisconnected = false
  while not windowShouldClose():
    game.resetMoveDirections()

    localRecorder.readInputs(keyBindings[localPlayer], isKeyDown, game.tick)
    session.sendReplay(localRecorder.flushChunk())

    let remoteMessage = session.receive()
    if remoteMessage.kind == Disconnect:
      echo "Peer disconnected."
      peerDisconnected = true
      break
    discard remotePlayer.playChunk(remoteMessage.chunk, game.tick)

    game.updateSimulation()

    beginDrawing()
    game.drawGame()
    endDrawing()

  if not peerDisconnected:
    session.sendDisconnect()

when isMainModule:
  main()
