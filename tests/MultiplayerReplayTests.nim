import std/[net, os]
import pkg/vmath
import unittest2
import ../src/[Input, Network, Pong, RaylibConverters]

suite "Multiplayer Replay System Sync Tests":
  test "Geometric collision primitives detect overlaps and bounds":
    let paddle = Rect(pos: vec2(30, 250), size: vec2(15, 100))
    check Circle(pos: vec2(50, 300), radius: 10).overlaps(paddle)
    check not Circle(pos: vec2(60, 300), radius: 10).overlaps(paddle)
    check Circle(pos: vec2(400, 5), radius: 10).outsideVerticalBounds(screenBounds)
    check Circle(pos: vec2(400, 595), radius: 10).outsideVerticalBounds(screenBounds)
    check not Circle(pos: vec2(400, 300), radius: 10).outsideVerticalBounds(screenBounds)

  test "Two peers negotiate frame time and synchronize game state over UDP":
    let hostSocket = newUdpSocket()
    hostSocket.bindAddr(Port(0))
    let (_, port) = hostSocket.getLocalAddr()

    let clientSocket = newUdpSocket()
    clientSocket.sendClientHello(ActionNames, "127.0.0.1", port.int)

    let negotiatedFps = 240
    let hostSession = hostSocket.acceptSession(ActionNames, fps = negotiatedFps)
    let clientSession = clientSocket.completeClientHandshake(ActionNames)
    defer:
      hostSession.close()
      clientSession.close()

    check hostSession.fixedFrameTime == clientSession.fixedFrameTime
    check clientSession.targetFps == negotiatedFps

    var hostGame = initPongGame(hostSession.fixedFrameTime)
    var clientGame = initPongGame(clientSession.fixedFrameTime)

    let hostActions = hostGame.makeActions()
    let clientActions = clientGame.makeActions()

    var hostRecorder = initReplayRecorder(hostActions)
    var hostRemotePlayer = initReplayPlayer(hostActions)

    var clientRecorder = initReplayRecorder(clientActions)
    var clientRemotePlayer = initReplayPlayer(clientActions)

    for tick in 0 ..< 240:
      hostGame.resetMoveDirections()
      clientGame.resetMoveDirections()

      hostRecorder.readInputs(
        keyBindings[Player1],
        proc(key: KeyboardKey): bool =
          key == KeyboardKey.W and (tick mod 2 == 0),
        hostGame.tick,
      )
      hostSession.sendReplay(hostRecorder.flushChunk())

      clientRecorder.readInputs(
        keyBindings[Player2],
        proc(key: KeyboardKey): bool =
          key == KeyboardKey.S and (tick mod 3 == 0),
        clientGame.tick,
      )
      clientSession.sendReplay(clientRecorder.flushChunk())

      let clientMessage = hostSession.receive()
      let hostMessage = clientSession.receive()
      check clientMessage.kind == ReplayUpdate
      check hostMessage.kind == ReplayUpdate

      let hostPlayback = hostRemotePlayer.playChunk(clientMessage.chunk, hostGame.tick)
      let clientPlayback = clientRemotePlayer.playChunk(hostMessage.chunk, clientGame.tick)
      check not hostPlayback.replayEnded
      check not clientPlayback.replayEnded

      hostGame.updateSimulation()
      clientGame.updateSimulation()

      check hostGame.players == clientGame.players
      check hostGame.ball == clientGame.ball
      check hostGame.ballVelocity == clientGame.ballVelocity

    clientSession.sendDisconnect()
    check hostSession.receive().kind == Disconnect

  test "Framerate negotiation enforces valid monitor FPS range":
    expect ValueError:
      validateTargetFps(minTargetFps - 1)
    expect ValueError:
      validateTargetFps(maxTargetFps + 1)
    validateTargetFps(minTargetFps)
    validateTargetFps(144)
    validateTargetFps(maxTargetFps)

  test "Input.nim file replay recording and playback works without NoopTick":
    let replayName = "/tmp/test_pong_replay"
    let replayFile = ActionNames.getReplayFilename(replayName)
    defer:
      if fileExists(replayFile):
        removeFile(replayFile)

    var recordedGame = initPongGame()
    var recorder = initReplayRecorder(replayName, recordedGame.makeActions())

    for tick in 0 ..< 60:
      recordedGame.resetMoveDirections()
      recorder.readInputs(
        keyBindings[Player1],
        proc(key: KeyboardKey): bool =
          key == KeyboardKey.W and tick < 30,
        recordedGame.tick,
      )
      recordedGame.updateSimulation()
    recorder.deinit()

    var replayedGame = initPongGame()
    var player = initReplayPlayer(replayName, replayedGame.makeActions())
    while true:
      replayedGame.resetMoveDirections()
      let playbackResult = player.play(replayedGame.tick)
      if playbackResult.replayEnded:
        break
      replayedGame.updateSimulation()
    player.deinit()

    check recordedGame.tick == replayedGame.tick
    check recordedGame.players == replayedGame.players
    check recordedGame.ball == replayedGame.ball
    check recordedGame.ballVelocity == replayedGame.ballVelocity
