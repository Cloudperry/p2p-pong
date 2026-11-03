import pkg/raylib
import std/[net, nativesockets, os]
import unittest2
import ../src/[Input, NetworkStream, Pong]

suite "Multiplayer Replay System Sync Tests":
  test "Two clients synchronize game state over TCP using ReplaySystem":
    var server = newSocket()
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0))
    let (_, port) = server.getLocalAddr()
    server.listen()

    var clientSock = newSocket()
    clientSock.connect("127.0.0.1", port)

    var hostSock: Socket
    var addrStr = ""
    server.acceptAddr(hostSock, addrStr)
    server.close()

    var hostGame = initPongGame()
    var clientGame = initPongGame()

    let hostActions = hostGame.makeActions()
    let clientActions = clientGame.makeActions()

    var hostRecorder = initStreamReplayRecorder[ActionNames](newSocketStream(hostSock), hostActions)
    var hostRemotePlayer = initStreamReplayPlayer[ActionNames](newSocketStream(hostSock), hostActions)

    var clientRecorder = initStreamReplayRecorder[ActionNames](newSocketStream(clientSock), clientActions)
    var clientRemotePlayer = initStreamReplayPlayer[ActionNames](newSocketStream(clientSock), clientActions)

    for tick in 0'u64 ..< 120'u64:
      hostGame.p1MoveDir = 0.0
      hostGame.p2MoveDir = 0.0
      clientGame.p1MoveDir = 0.0
      clientGame.p2MoveDir = 0.0

      # Host local inputs
      hostRecorder.recordFrameData(NoopTick, hostGame.tickN, true, true)
      hostRecorder.recordFrameData(SetDeltaTime, hostGame.tickN, fixedDeltaTime, true)
      hostRecorder.addRecordingInputReader(
        p1KeyBindings,
        proc(k: KeyboardKey): bool =
          k == KeyboardKey.W and (tick mod 2 == 0),
        hostGame.tickN,
        hostGame.deltaTime,
        true,
      )
      hostRecorder.flush()

      # Client local inputs
      clientRecorder.recordFrameData(NoopTick, clientGame.tickN, true, true)
      clientRecorder.addRecordingInputReader(
        p2KeyBindings,
        proc(k: KeyboardKey): bool =
          k == KeyboardKey.S and (tick mod 3 == 0),
        clientGame.tickN,
        clientGame.deltaTime,
        true,
      )
      clientRecorder.flush()

      # Both play remote actions
      let hostPlay = hostRemotePlayer.play(hostGame.tickN)
      let clientPlay = clientRemotePlayer.play(clientGame.tickN)

      check not hostPlay.replayEnded
      check not clientPlay.replayEnded

      hostGame.updateSimulation()
      clientGame.updateSimulation()

      check hostGame.p1Y == clientGame.p1Y
      check hostGame.p2Y == clientGame.p2Y
      check hostGame.ballPos == clientGame.ballPos
      check hostGame.ballVel == clientGame.ballVel
      check hostGame.score1 == clientGame.score1
      check hostGame.score2 == clientGame.score2

    hostSock.close()
    clientSock.close()

  test "File replay recording and playback matches simulation":
    let replayName = "/tmp/test_pong_replay"
    let replayFile = ActionNames.getReplayFilename(replayName)

    var game1 = initPongGame()
    var recorder = initReplayRecorder[ActionNames](replayName, game1.makeActions())

    for tick in 0'u64 ..< 60'u64:
      game1.p1MoveDir = 0.0
      game1.p2MoveDir = 0.0
      recorder.recordFrameData(NoopTick, game1.tickN, true, true)
      recorder.recordFrameData(SetDeltaTime, game1.tickN, fixedDeltaTime, true)
      recorder.addRecordingInputReader(
        p1KeyBindings,
        proc(k: KeyboardKey): bool =
          k == KeyboardKey.W,
        game1.tickN,
        game1.deltaTime,
        true,
      )
      game1.updateSimulation()
    recorder.deinit()

    var game2 = initPongGame()
    var player = initReplayPlayer[ActionNames](replayName, game2.makeActions())
    while true:
      game2.p1MoveDir = 0.0
      game2.p2MoveDir = 0.0
      let res = player.play(game2.tickN)
      if res.replayEnded:
        break
      game2.updateSimulation()
    player.deinit()

    check game1.tickN == game2.tickN
    check game1.p1Y == game2.p1Y
    check game1.p2Y == game2.p2Y
    check game1.ballPos == game2.ballPos
    check game1.ballVel == game2.ballVel
    removeFile(replayFile)
