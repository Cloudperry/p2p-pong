import std/[tables, streams, strformat, times, monotimes, options]
import pkg/[glm, flatty]
import ./[Containers]

const replayBufSize* = 1024

type
  ActionKind* = enum
    BoolAction
    FloatAction
    Vector2Action
    MonoTimeAction

  BoolActionFn* = proc(active: bool)
  FloatActionFn* = proc(value: float)
  Vec2ActionFn* = proc(value: Vec2f)
  MonoTimeActionFn* = proc(value: MonoTime)
  ActionInputs* = object
    case kind*: ActionKind
    of BoolAction:
      boolVal*: bool
    of FloatAction:
      floatVal*: float
    of Vector2Action:
      vec2Val*: Vec2f
    of MonoTimeAction:
      monoTimeVal*: MonoTime

  Action* = object
    runOnlyWhenNonZero: bool
    case kind: ActionKind
    of BoolAction:
      boolFn: BoolActionFn
    of FloatAction:
      floatFn: FloatActionFn
    of Vector2Action:
      vec2Fn: Vec2ActionFn
    of MonoTimeAction:
      monoTimeFn: MonoTimeActionFn

  ## Maps action names to the callbacks that handle them.
  Actions*[A: enum] = Table[A, Action]
  ## A single recorded action: which action, its input value and the tick it happened on.
  RecordedAction*[A: enum] = object
    tickN*: uint64
    inputs*: ActionInputs
    actionName*: A

  ReplaySystemMode* = enum
    InputOnly
    Player
    Recorder

  ReplayBuffer*[A: enum] = CircularBuffer[replayBufSize, RecordedAction[A]]
  ## Drives input in one of three modes: live input, recording to a stream, or replaying from a stream.
  ReplaySystem*[A] = object
    buf*: ReplayBuffer[A]
    actions*: Actions[A]
    replayStream*: Stream
    case mode*: ReplaySystemMode
    of Recorder, InputOnly:
      discard
    of Player:
      lastPlayedI*: int = -1

proc getReplayFilename*[O: enum | object](
    storableObjectName: typedesc[O], replayName: string
): string =
  ## Builds the replay file name for a given replay name, namespaced by the stored type.
  fmt"{replayName}.{$storableObjectName}.replay"

proc initReplayRecorder*[A](replayName: string, actions: Actions[A]): ReplaySystem[A] =
  ## Creates a replay system that runs actions from live input and records them to a file.
  let filename = A.getReplayFilename(replayName)
  return ReplaySystem[A](
    mode: Recorder, replayStream: newFileStream(filename, fmAppend), actions: actions
  )

proc initStreamReplayRecorder*[A](stream: Stream, actions: Actions[A]): ReplaySystem[A] =
  ## Creates a replay system that runs actions from live input and records them to a Stream.
  return ReplaySystem[A](
    mode: Recorder, replayStream: stream, actions: actions
  )

proc initInputSystem*[A](actions: Actions[A]): ReplaySystem[A] =
  ## Creates a replay system that only runs live input, without recording or playback.
  ReplaySystem[A](mode: InputOnly, actions: actions)

proc `==`*[A](r1, r2: ReplaySystem[A]): bool =
  r1.mode == r2.mode and r1.buf == r2.buf and r1.replayStream == r2.replayStream

proc writeFile*[A](rs: var ReplaySystem[A]) =
  if rs.buf.i != 0:
    for i in rs.buf.i ..< replayBufSize:
      rs.buf.data[i] = RecordedAction[A].default
  let replayBufBytes = toFlatty(rs.buf)
  rs.replayStream.write(replayBufBytes)
  rs.replayStream.flush()
  rs.buf = ReplayBuffer[A].default

proc flush*[A](rs: var ReplaySystem[A]) =
  ## Explicitly flushes the current replay buffer to the stream.
  rs.writeFile()

proc recordActionAndFlushToFile*[A](
    rs: var ReplaySystem[A], action: sink RecordedAction[A]
) =
  rs.buf.push action
  if rs.buf.i == 0:
    rs.writeFile()

proc deinit*[A](rs: var ReplaySystem[A]) =
  ## Flushes any buffered recorded actions to disk (when recording) and closes the stream.
  if rs.mode == Recorder and rs != ReplaySystem[A].default and rs.buf.i != 0:
    rs.writeFile()
  if not rs.replayStream.isNil:
    rs.replayStream.close()

proc `==`*(a1, a2: ActionInputs): bool =
  return
    (a1.kind == a2.kind and a1.kind == BoolAction and a1.boolVal == a2.boolVal) or
    (a1.kind == a2.kind and a1.kind == FloatAction and a1.floatVal == a2.floatVal) or
    (a1.kind == a2.kind and a1.kind == Vector2Action and a1.vec2Val == a2.vec2Val) or (
      a1.kind == a2.kind and a1.kind == MonoTimeAction and
      a1.monoTimeVal == a2.monoTimeVal
    )

proc wrapInput*[T](val: T): ActionInputs =
  when T is bool:
    result = ActionInputs(kind: BoolAction, boolVal: val)
  elif T is float:
    result = ActionInputs(kind: FloatAction, floatVal: val)
  elif T is Vec2f:
    result = ActionInputs(kind: Vector2Action, vec2Val: val)
  elif T is MonoTime:
    result = ActionInputs(kind: MonoTimeAction, monoTimeVal: val)
  else:
    {.error: "Unsupported input value type".}

proc run*(action: Action, i: ActionInputs): bool =
  case action.kind
  of BoolAction:
    if not action.runOnlyWhenNonZero or i.boolVal != bool.default:
      action.boolFn(i.boolVal)
      return true
  of FloatAction:
    if not action.runOnlyWhenNonZero or i.floatVal != float.default:
      action.floatFn(i.floatVal)
      return true
  of Vector2Action:
    if not action.runOnlyWhenNonZero or i.vec2Val != Vec2f.default:
      action.vec2Fn(i.vec2Val)
      return true
  of MonoTimeAction:
    if not action.runOnlyWhenNonZero or i.monoTimeVal != MonoTime.default:
      action.monoTimeFn(i.monoTimeVal)
      return true
  return false

proc run*[A: enum](actions: Actions[A], actionName: A, i: ActionInputs): bool =
  actions[actionName].run(i)

proc initBoolAction*(fn: BoolActionFn, runOnlyWhenNonZero = true): Action =
  Action(kind: BoolAction, boolFn: fn, runOnlyWhenNonZero: runOnlyWhenNonZero)

proc initFloatAction*(fn: FloatActionFn, runOnlyWhenNonZero = true): Action =
  Action(kind: FloatAction, floatFn: fn, runOnlyWhenNonZero: runOnlyWhenNonZero)

proc initVector2Action*(fn: Vec2ActionFn, runOnlyWhenNonZero = true): Action =
  Action(kind: Vector2Action, vec2Fn: fn, runOnlyWhenNonZero: runOnlyWhenNonZero)

proc initMonoTimeAction*(fn: MonoTimeActionFn, runOnlyWhenNonZero = true): Action =
  Action(kind: MonoTimeAction, monoTimeFn: fn, runOnlyWhenNonZero: runOnlyWhenNonZero)

type InputsToActions*[A: enum, I] = Table[I, A]

proc addRecordingInputReader*[A, I: enum, T](
    rs: var ReplaySystem[A],
    inputsToActions: InputsToActions[A, I],
    reader: proc(inputName: I): T,
    tickN: uint64,
    deltaTime: float,
    recordingEnabled: bool,
) =
  ## Reads each mapped input via `reader`, runs its action, and (when recording) records the
  ## actions that actually fired so they can be replayed for this tick.
  for inputName, actionName in inputsToActions.pairs:
    if actionName in rs.actions:
      let input = reader(inputName).wrapInput()
      let actionExecuted = rs.actions.run(actionName, input)
      if recordingEnabled and actionExecuted:
        rs.recordActionAndFlushToFile RecordedAction[A](
          actionName: actionName, inputs: input, tickN: tickN
        )

proc recordFrameData*[A, T](
    rs: var ReplaySystem[A],
    setterName: A,
    tickN: uint64,
    data: T,
    recordingEnabled: bool,
) =
  ## Records one piece of per-frame data (e.g. delta/mono time) for a tick so playback
  ## reproduces the same timing. No-op when recording is disabled.
  if recordingEnabled:
    let input = wrapInput(data)
    rs.recordActionAndFlushToFile RecordedAction[A](
      actionName: setterName, inputs: input, tickN: tickN
    )

proc initReplayPlayer*[A](replayName: string, actions: Actions[A]): ReplaySystem[A] =
  ## Opens a recorded replay file for playback, asserting the file exists.
  let filename = A.getReplayFilename(replayName)
  result = ReplaySystem[A](
    mode: Player, replayStream: newFileStream(filename, fmRead), actions: actions
  )
  doAssert not result.replayStream.isNil, fmt"Could not open replay file: {filename}"

proc initStreamReplayPlayer*[A](stream: Stream, actions: Actions[A]): ReplaySystem[A] =
  ## Creates a replay system that plays back recorded actions from a Stream.
  result = ReplaySystem[A](
    mode: Player, replayStream: stream, actions: actions
  )

type ReplayPlaybackResult*[A: enum] = object
  replayEnded*: bool
  playedActions*: seq[RecordedAction[A]]

proc readNewBuf*[A](rs: var ReplaySystem[A]): bool =
  if rs.replayStream.atEnd():
    return false
  else:
    let expectedBytes = toFlatty(ReplayBuffer[A].default).len
    let replayBufBytes = rs.replayStream.readStr(expectedBytes)
    if replayBufBytes.len < expectedBytes:
      return false
    rs.buf = replayBufBytes.fromFlatty(ReplayBuffer[A])
    return true

proc findLastActionI[A](rs: ReplaySystem[A]): int =
  for i in countdown(rs.buf.data.high, 0):
    let recordedAction = rs.buf.data[i]
    if recordedAction != RecordedAction[A].default:
      return i

proc play*[A](rs: var ReplaySystem[A], tickN: uint64): ReplayPlaybackResult[A] =
  ## Plays back all recorded actions for the given tick, refilling the buffer from the stream
  ## as needed. Returns whether the replay is playing or not and which action was executed.
  result.replayEnded = false

  var i = max(0, rs.lastPlayedI + 1)
  while true:
    let lastActionI = rs.findLastActionI()
    let lastTickN = rs.buf.data[lastActionI].tickN
    let newBufferNeeded =
      rs.buf == ReplayBuffer[A].default or tickN > lastTickN or
      (tickN == lastTickN and rs.lastPlayedI >= lastActionI)
    if newBufferNeeded:
      if not rs.readNewBuf():
        result.replayEnded = true
        return
      else:
        i = 0
        rs.lastPlayedI = -1

    let recordedAction = rs.buf.data[i]
    if recordedAction == RecordedAction[A].default:
      result.replayEnded = true
      return
    elif recordedAction.tickN > tickN:
      break
    elif recordedAction.tickN == tickN:
      if rs.actions[recordedAction.actionName].run(recordedAction.inputs):
        result.playedActions.add recordedAction

    rs.lastPlayedI = i
    let postLastActionI = rs.findLastActionI()
    if i >= postLastActionI:
      # Reached the last recorded action in this buffer; wait until the next tick to read more
      break
    i += 1

type StateStorage* = object
  stateFilename: string

proc getDataBlobFilename*[O: object](
    storableObjectName: typedesc[O], dataBlobName: string
): string =
  fmt"{dataBlobName}.{$storableObjectName}.bin"

proc initStateStorage*[S: object](dataBlobName: string): StateStorage =
  StateStorage(stateFilename: S.getDataBlobFilename(dataBlobName))

proc saveState*[S: object](ss: StateStorage, so: S) =
  let stateFileBytes = toFlatty(so)
  writeFile(ss.stateFilename, stateFileBytes)

proc loadState*[S: object](ss: StateStorage, stateObjectT: typedesc[S]): S =
  let stateFileBytes = readFile(ss.stateFilename)
  return stateFileBytes.fromFlatty(S)
