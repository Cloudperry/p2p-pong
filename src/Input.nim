import std/[tables, streams, strformat, times, monotimes]
import pkg/[vmath, flatty]
import ./[Containers]

const replayBufferSize* = 1024

type
  ActionKind* = enum
    BoolAction
    FloatAction
    Vector2Action
    MonoTimeAction

  BoolActionCallback* = proc(active: bool)
  FloatActionCallback* = proc(value: float)
  Vec2ActionCallback* = proc(value: Vec2)
  MonoTimeActionCallback* = proc(value: MonoTime)

  ActionInputs* = object
    case kind*: ActionKind
    of BoolAction:
      boolValue*: bool
    of FloatAction:
      floatValue*: float
    of Vector2Action:
      vec2Value*: Vec2
    of MonoTimeAction:
      monoTimeValue*: MonoTime

  Action* = object
    runOnlyWhenNonZero: bool
    case kind: ActionKind
    of BoolAction:
      boolCallback: BoolActionCallback
    of FloatAction:
      floatCallback: FloatActionCallback
    of Vector2Action:
      vec2Callback: Vec2ActionCallback
    of MonoTimeAction:
      monoTimeCallback: MonoTimeActionCallback

  ## Maps action names to the callbacks that handle them.
  Actions*[A: enum] = Table[A, Action]
  ## A single recorded action: which action, its input value and the tick it happened on.
  RecordedAction*[A: enum] = object
    tick*: int
    inputs*: ActionInputs
    actionName*: A

  ReplaySystemMode* = enum
    InputOnly
    Player
    Recorder

  ReplayBuffer*[A: enum] = CircularBuffer[replayBufferSize, RecordedAction[A]]

  ## A serializable batch of recorded actions covering ticks up to `lastTick`.
  ReplayChunk*[A: enum] = object
    hasTicks*: bool
    partialTick*: bool
    lastTick*: int
    actions*: seq[RecordedAction[A]]

  ## Drives input in one of three modes: live input, recording, or replaying.
  ReplaySystem*[A: enum] = object
    actions*: Actions[A]
    replayStream*: Stream
    case mode*: ReplaySystemMode
    of InputOnly:
      discard
    of Recorder:
      buffer*: ReplayBuffer[A]
      hasPendingTicks*: bool
      lastRecordedTick*: int
    of Player:
      currentChunk*: ReplayChunk[A]
      nextActionIndex*: int = 0

proc getReplayFilename*[O: enum | object](
    storableObjectType: typedesc[O], replayName: string
): string =
  ## Builds the replay file name for a given replay name, namespaced by the stored type.
  fmt"{replayName}.{$storableObjectType}.replay"

proc initInputSystem*[A: enum](actions: Actions[A]): ReplaySystem[A] =
  ## Creates a replay system that only runs live input, without recording or playback.
  ReplaySystem[A](mode: InputOnly, actions: actions)

proc initReplayRecorder*[A: enum](actions: Actions[A]): ReplaySystem[A] =
  ## Creates an in-memory replay recorder (used for multiplayer chunk flushing).
  ReplaySystem[A](mode: Recorder, actions: actions)

proc initStreamReplayRecorder*[A: enum](
    stream: Stream, actions: Actions[A]
): ReplaySystem[A] =
  ## Creates a replay system that runs actions from live input and records them to a Stream.
  ReplaySystem[A](mode: Recorder, replayStream: stream, actions: actions)

proc initReplayRecorder*[A: enum](
    replayName: string, actions: Actions[A]
): ReplaySystem[A] =
  ## Creates a replay system that runs actions from live input and records them to a file.
  let filename = A.getReplayFilename(replayName)
  ReplaySystem[A](
    mode: Recorder,
    replayStream: newFileStream(filename, fmWrite),
    actions: actions,
  )

proc flushChunk*[A: enum](
    replaySystem: var ReplaySystem[A], partialTick = false
): ReplayChunk[A] =
  ## Extracts buffered recorded actions into a serializable ReplayChunk and resets the buffer.
  result = ReplayChunk[A](
    hasTicks: replaySystem.hasPendingTicks,
    partialTick: partialTick,
    lastTick: replaySystem.lastRecordedTick,
    actions: newSeqOfCap[RecordedAction[A]](replaySystem.buffer.writeIndex),
  )
  for index in 0 ..< replaySystem.buffer.writeIndex:
    result.actions.add(replaySystem.buffer.data[index])
  replaySystem.buffer.writeIndex = 0
  replaySystem.hasPendingTicks = false

proc writeChunkToStream[A: enum](
    replaySystem: var ReplaySystem[A], chunk: ReplayChunk[A]
) =
  let chunkBytes = toFlatty(chunk)
  replaySystem.replayStream.write(uint32(chunkBytes.len))
  replaySystem.replayStream.write(chunkBytes)
  replaySystem.replayStream.flush()

proc flush*[A: enum](replaySystem: var ReplaySystem[A]) =
  ## Explicitly flushes the current replay buffer to the stream.
  if replaySystem.mode == Recorder and not replaySystem.replayStream.isNil and
      replaySystem.hasPendingTicks:
    let chunk = replaySystem.flushChunk()
    replaySystem.writeChunkToStream(chunk)

proc recordAction*[A: enum](
    replaySystem: var ReplaySystem[A], action: sink RecordedAction[A]
) =
  replaySystem.hasPendingTicks = true
  replaySystem.lastRecordedTick = max(replaySystem.lastRecordedTick, action.tick)
  replaySystem.buffer.push(action)
  if replaySystem.buffer.writeIndex == 0 and not replaySystem.replayStream.isNil:
    var fullChunk = ReplayChunk[A](
      hasTicks: true,
      partialTick: true,
      lastTick: replaySystem.lastRecordedTick,
      actions: newSeqOfCap[RecordedAction[A]](replayBufferSize),
    )
    for item in replaySystem.buffer.data:
      fullChunk.actions.add(item)
    replaySystem.writeChunkToStream(fullChunk)
    replaySystem.hasPendingTicks = false

proc deinit*[A: enum](replaySystem: var ReplaySystem[A]) =
  ## Flushes any buffered recorded actions to the stream (when recording) and closes it.
  if replaySystem.mode == Recorder and not replaySystem.replayStream.isNil and
      replaySystem.hasPendingTicks:
    replaySystem.flush()
  if not replaySystem.replayStream.isNil:
    replaySystem.replayStream.close()

proc `==`*(first, second: ActionInputs): bool =
  if first.kind != second.kind:
    return false
  case first.kind
  of BoolAction:
    first.boolValue == second.boolValue
  of FloatAction:
    first.floatValue == second.floatValue
  of Vector2Action:
    first.vec2Value == second.vec2Value
  of MonoTimeAction:
    first.monoTimeValue == second.monoTimeValue

proc wrapInput*[T](value: T): ActionInputs =
  when T is bool:
    ActionInputs(kind: BoolAction, boolValue: value)
  elif T is SomeFloat:
    ActionInputs(kind: FloatAction, floatValue: float(value))
  elif T is Vec2:
    ActionInputs(kind: Vector2Action, vec2Value: value)
  elif T is MonoTime:
    ActionInputs(kind: MonoTimeAction, monoTimeValue: value)
  else:
    {.error: "Unsupported input value type".}

proc run*(action: Action, input: ActionInputs): bool =
  case action.kind
  of BoolAction:
    if not action.runOnlyWhenNonZero or input.boolValue != bool.default:
      action.boolCallback(input.boolValue)
      return true
  of FloatAction:
    if not action.runOnlyWhenNonZero or input.floatValue != float.default:
      action.floatCallback(input.floatValue)
      return true
  of Vector2Action:
    if not action.runOnlyWhenNonZero or input.vec2Value != Vec2.default:
      action.vec2Callback(input.vec2Value)
      return true
  of MonoTimeAction:
    if not action.runOnlyWhenNonZero or input.monoTimeValue != MonoTime.default:
      action.monoTimeCallback(input.monoTimeValue)
      return true
  return false

proc run*[A: enum](actions: Actions[A], actionName: A, input: ActionInputs): bool =
  actions[actionName].run(input)

proc initBoolAction*(callback: BoolActionCallback, runOnlyWhenNonZero = true): Action =
  Action(kind: BoolAction, boolCallback: callback, runOnlyWhenNonZero: runOnlyWhenNonZero)

proc initFloatAction*(
    callback: FloatActionCallback, runOnlyWhenNonZero = true
): Action =
  Action(kind: FloatAction, floatCallback: callback, runOnlyWhenNonZero: runOnlyWhenNonZero)

proc initVector2Action*(
    callback: Vec2ActionCallback, runOnlyWhenNonZero = true
): Action =
  Action(kind: Vector2Action, vec2Callback: callback, runOnlyWhenNonZero: runOnlyWhenNonZero)

proc initMonoTimeAction*(
    callback: MonoTimeActionCallback, runOnlyWhenNonZero = true
): Action =
  Action(
    kind: MonoTimeAction,
    monoTimeCallback: callback,
    runOnlyWhenNonZero: runOnlyWhenNonZero,
  )

type InputsToActions*[A: enum, I] = Table[I, A]

proc readInputs*[A: enum, I: enum, T](
    replaySystem: var ReplaySystem[A],
    inputsToActions: InputsToActions[A, I],
    reader: proc(inputName: I): T,
    tick: int,
    recordingEnabled = true,
) =
  ## Reads each mapped input via `reader`, runs its action, and (when recording) records the
  ## actions that actually fired so they can be replayed for this tick.
  let shouldRecord = replaySystem.mode == Recorder and recordingEnabled
  if shouldRecord:
    replaySystem.hasPendingTicks = true
    replaySystem.lastRecordedTick = max(replaySystem.lastRecordedTick, tick)

  for inputName, actionName in inputsToActions.pairs:
    if actionName in replaySystem.actions:
      let input = reader(inputName).wrapInput()
      let actionExecuted = replaySystem.actions.run(actionName, input)
      if shouldRecord and actionExecuted:
        replaySystem.recordAction(
          RecordedAction[A](actionName: actionName, inputs: input, tick: tick)
        )

proc recordFrameData*[A: enum, T](
    replaySystem: var ReplaySystem[A],
    setterName: A,
    tick: int,
    data: T,
    recordingEnabled = true,
) =
  ## Records one piece of per-frame data (e.g. delta/mono time) for a tick so playback
  ## reproduces the same timing. No-op when recording is disabled or not in Recorder mode.
  if replaySystem.mode == Recorder and recordingEnabled:
    let input = wrapInput(data)
    replaySystem.recordAction(
      RecordedAction[A](actionName: setterName, inputs: input, tick: tick)
    )

proc initReplayPlayer*[A: enum](actions: Actions[A]): ReplaySystem[A] =
  ## Creates an in-memory replay player (used for playing received multiplayer chunks).
  ReplaySystem[A](mode: Player, actions: actions)

proc initStreamReplayPlayer*[A: enum](
    stream: Stream, actions: Actions[A]
): ReplaySystem[A] =
  ## Creates a replay system that plays back recorded actions from a Stream.
  ReplaySystem[A](mode: Player, replayStream: stream, actions: actions)

proc initReplayPlayer*[A: enum](
    replayName: string, actions: Actions[A]
): ReplaySystem[A] =
  ## Opens a recorded replay file for playback, asserting the file exists.
  let filename = A.getReplayFilename(replayName)
  result = ReplaySystem[A](
    mode: Player, replayStream: newFileStream(filename, fmRead), actions: actions
  )
  doAssert not result.replayStream.isNil, fmt"Could not open replay file: {filename}"

type ReplayPlaybackResult*[A: enum] = object
  replayEnded*: bool
  playedActions*: seq[RecordedAction[A]]

proc loadChunk*[A: enum](
    replaySystem: var ReplaySystem[A], chunk: sink ReplayChunk[A]
) =
  ## Loads a ReplayChunk into the player for playback.
  replaySystem.currentChunk = chunk
  replaySystem.nextActionIndex = 0

proc readNextChunk[A: enum](replaySystem: var ReplaySystem[A]): bool =
  if replaySystem.replayStream.isNil or replaySystem.replayStream.atEnd():
    return false
  var chunkByteLen: uint32 = 0
  let headerBytes = replaySystem.replayStream.readData(addr chunkByteLen, sizeof(uint32))
  if headerBytes < sizeof(uint32):
    return false
  let chunkBytes = replaySystem.replayStream.readStr(int(chunkByteLen))
  if chunkBytes.len < int(chunkByteLen):
    return false
  replaySystem.loadChunk(chunkBytes.fromFlatty(ReplayChunk[A]))
  return true

proc play*[A: enum](
    replaySystem: var ReplaySystem[A], tick: int
): ReplayPlaybackResult[A] =
  ## Plays back all recorded actions for the given tick, refilling from the stream
  ## as needed. Returns whether the replay has ended and which actions were executed.
  while true:
    let needsNewChunk =
      not replaySystem.currentChunk.hasTicks or
      tick > replaySystem.currentChunk.lastTick
    if needsNewChunk:
      if not replaySystem.readNextChunk():
        result.replayEnded = true
        return

    while replaySystem.nextActionIndex < replaySystem.currentChunk.actions.len:
      let recordedAction = replaySystem.currentChunk.actions[replaySystem.nextActionIndex]
      if recordedAction.tick > tick:
        return
      if recordedAction.tick == tick:
        if replaySystem.actions[recordedAction.actionName].run(recordedAction.inputs):
          result.playedActions.add(recordedAction)
      replaySystem.nextActionIndex += 1

    if replaySystem.currentChunk.partialTick and tick == replaySystem.currentChunk.lastTick:
      if not replaySystem.readNextChunk():
        return
    else:
      return

proc playChunk*[A: enum](
    replaySystem: var ReplaySystem[A], chunk: sink ReplayChunk[A], tick: int
): ReplayPlaybackResult[A] =
  ## Loads an in-memory ReplayChunk and immediately plays back its actions for `tick`.
  replaySystem.loadChunk(chunk)
  replaySystem.play(tick)

type StateStorage* = object
  stateFilename: string

proc getDataBlobFilename*[O: object](
    storableObjectType: typedesc[O], dataBlobName: string
): string =
  fmt"{dataBlobName}.{$storableObjectType}.bin"

proc initStateStorage*[S: object](dataBlobName: string): StateStorage =
  StateStorage(stateFilename: S.getDataBlobFilename(dataBlobName))

proc saveState*[S: object](stateStorage: StateStorage, stateObject: S) =
  let stateFileBytes = toFlatty(stateObject)
  writeFile(stateStorage.stateFilename, stateFileBytes)

proc loadState*[S: object](
    stateStorage: StateStorage, stateObjectType: typedesc[S]
): S =
  let stateFileBytes = readFile(stateStorage.stateFilename)
  return stateFileBytes.fromFlatty(S)
