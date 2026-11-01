import Foundation

@main
enum IOSUnityLifecycleBoundaryTests {
  static func main() {
    var assertions = 0
    func check(_ value: Bool, _ label: String) {
      assertions += 1
      guard value else {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
      }
    }
    func expect(
      _ actual: [UnityAvatarLifecycleEvent],
      _ expected: [UnityAvatarLifecycleEvent],
      _ label: String
    ) {
      check(actual == expected, "\(label): \(actual) != \(expected)")
    }

    var attachment = UnityAvatarAttachmentState()
    check(attachment.requestedGeneration == nil,
          "scene activation alone cannot request or start a Unity view")
    attachment.request()
    let deferredAttach = attachment.requestedGeneration!
    attachment.request()
    check(attachment.requestedGeneration == deferredAttach,
          "repeated prepareView shares the same attachment lifecycle")
    var retainedReady = UnityAvatarLifecycleState()
    _ = retainedReady.playerDidStart(fallbackHostPhase: .active)
    _ = retainedReady.receive(.didEnterBackground)
    _ = retainedReady.receive(.willEnterForeground)
    check(retainedReady.hostPhase == .inactive && attachment.isCurrent(deferredAttach),
          "prepare while inactive retains its request despite an already initialized player")
    _ = retainedReady.receive(.didBecomeActive)
    check(retainedReady.hostPhase == .active && attachment.isCurrent(deferredAttach),
          "actual scene activation can replay attachment without a new renderer-ready event")
    attachment.detach()
    check(!attachment.isCurrent(deferredAttach) && attachment.requestedGeneration == nil,
          "detach cancels queued activation and superview attachment callbacks")
    attachment.request()
    let replacementAttach = attachment.requestedGeneration!
    check(replacementAttach != deferredAttach && !attachment.isCurrent(deferredAttach),
          "an old queued callback cannot attach a replacement owner")
    check(attachment.isCurrent(replacementAttach), "current attachment stays valid")

    attachment.request(presentationId: "first-view")
    let firstView = attachment.requestedGeneration!
    check(attachment.presentationId == "first-view", "attachment carries Flutter's exact view request")
    attachment.request(presentationId: "first-view")
    check(attachment.requestedGeneration == firstView, "bounded retry keeps its view identity")
    attachment.request(presentationId: "resumed-view")
    check(!attachment.isCurrent(firstView), "new resume request rejects a deferred old attachment")
    check(attachment.presentationId == "resumed-view", "new native receipt echoes the current request")
    let resumedView = attachment.requestedGeneration!
    attachment.request()
    check(attachment.requestedGeneration == resumedView && attachment.presentationId == "resumed-view",
          "UIKit activation preserves Flutter's current request identity")
    attachment.detach()
    check(attachment.presentationId == nil && !attachment.isCurrent(resumedView),
          "detach retires both the view request and queued native callbacks")

    var state = UnityAvatarLifecycleState()
    expect(state.receive(.willEnterForeground), [], "no player on scene connection")
    expect(state.receive(.didBecomeActive), [], "no cold start on scene activation")
    check(state.hostPhase == .active && state.playerPhase == nil,
          "pre-attach events record the host without claiming delivery")
    expect(state.playerDidStart(fallbackHostPhase: .active), [],
           "runEmbedded has already activated a foreground player")
    expect(state.playerDidStart(fallbackHostPhase: .background), [],
           "repeated prepare does not reinitialize lifecycle")

    // Match UnityAppController's explicit-pause bookkeeping. A duplicate
    // willResignActive would turn an OS pause into an explicit user pause and
    // prevent didBecomeActive from resuming the player.
    var player = RecordingUnityPlayer()
    for cycle in 0..<20 {
      let resign = state.receive(.willResignActive)
      expect(resign, [.willResignActive], "lock \(cycle) resigns once")
      player.apply(resign)
      let duplicate = state.receive(.willResignActive)
      expect(duplicate, [], "duplicate resign does not poison explicit pause")
      player.apply(duplicate)
      check(!player.explicitlyPaused, "OS pause stays resumable")
      let background = state.receive(.didEnterBackground)
      expect(background, [.didEnterBackground], "background does not resign twice")
      player.apply(background)
      expect(state.receive(.didEnterBackground), [], "duplicate background ignored")
      check(!player.running && !player.displayLinkRunning, "background stops rendering")
      let foreground = state.receive(.willEnterForeground)
      expect(foreground, [.willEnterForeground], "foreground resumes display link first")
      player.apply(foreground)
      expect(state.receive(.willEnterForeground), [], "duplicate foreground ignored")
      check(!player.running && player.displayLinkRunning,
            "foreground does not activate player before scene activation")
      let active = state.receive(.didBecomeActive)
      expect(active, [.didBecomeActive], "scene activation follows foreground")
      player.apply(active)
      expect(state.receive(.didBecomeActive), [], "duplicate activation ignored")
      check(player.running && !player.explicitlyPaused, "unlock resumes player")
    }

    expect(state.receive(.willResignActive), [.willResignActive],
           "control center resigns without background")
    expect(state.receive(.didBecomeActive), [.didBecomeActive],
           "control center dismissal does not synthesize foreground")
    expect(state.receive(.willEnterForeground), [],
           "late duplicate foreground cannot pause an already active scene")

    var late = UnityAvatarLifecycleState()
    expect(late.receive(.willResignActive), [], "inactive before player readiness")
    expect(late.receive(.didEnterBackground), [], "background before player readiness")
    check(late.hostPhase == .background && late.playerPhase == nil,
          "initializing player has not consumed background transition")
    expect(late.playerDidStart(fallbackHostPhase: .active),
           [.willResignActive, .didEnterBackground],
           "late-ready player catches up to recorded background despite stale fallback")
    expect(late.playerDidStart(fallbackHostPhase: .active), [],
           "second ready callback never resigns the paused player again")
    expect(late.receive(.didBecomeActive), [.willEnterForeground, .didBecomeActive],
           "missing foreground callback is repaired in order")
    expect(late.receive(.didEnterBackground), [.willResignActive, .didEnterBackground],
           "missing resign callback is repaired in order")
    expect(late.receive(.willResignActive), [],
           "late resign after background cannot repeat engine pause")
    expect(late.receive(.willEnterForeground), [.willEnterForeground],
           "interrupted unlock begins foreground")
    expect(late.receive(.willResignActive), [],
           "relock before active keeps the player paused")
    expect(late.receive(.didEnterBackground), [.didEnterBackground],
           "relock stops display link without a second resign")

    for phase in [UnityAvatarScenePhase.active, .inactive, .background] {
      var noCallbacks = UnityAvatarLifecycleState()
      let expected: [UnityAvatarLifecycleEvent]
      switch phase {
      case .active: expected = []
      case .inactive: expected = [.willResignActive]
      case .background: expected = [.willResignActive, .didEnterBackground]
      }
      expect(noCallbacks.playerDidStart(fallbackHostPhase: phase), expected,
             "late attachment can sample current application phase \(phase)")
      check(noCallbacks.hostPhase == phase && noCallbacks.playerPhase == phase,
            "late attachment reaches the sampled phase")
    }

    var startupInterrupted = UnityAvatarLifecycleState()
    expect(startupInterrupted.receive(.willEnterForeground), [], "startup foreground records intent")
    expect(startupInterrupted.receive(.willResignActive), [], "startup interruption stays inactive")
    expect(startupInterrupted.playerDidStart(fallbackHostPhase: .active), [.willResignActive],
           "ready during startup interruption pauses once")
    expect(startupInterrupted.receive(.didBecomeActive), [.didBecomeActive],
           "startup interruption recovery is resumable")

    // UIKit callback scheduling is external to this pure state machine. Replay
    // the same event trace at virtual timestamps; no wall-clock sleep is needed
    // and the state must not expire during the user's 30–60 second lock interval.
    for lockedSeconds in [0, 30, 45, 60, 3600] {
      var timedState = UnityAvatarLifecycleState()
      var timedPlayer = RecordingUnityPlayer()
      timedPlayer.apply(timedState.playerDidStart(fallbackHostPhase: .active))
      let trace: [(Int, UnityAvatarLifecycleEvent)] = [
        (0, .willResignActive),
        (0, .didEnterBackground),
        (lockedSeconds, .willEnterForeground),
        (lockedSeconds, .didBecomeActive),
      ]
      var delivered: [UnityAvatarLifecycleEvent] = []
      for (timestamp, event) in trace {
        let events = timedState.receive(event)
        timedPlayer.apply(events)
        delivered.append(contentsOf: events)
        check(!timedPlayer.explicitlyPaused,
              "virtual \(lockedSeconds)s lock at \(timestamp)s does not invent an explicit pause")
      }
      expect(delivered, [.willResignActive, .didEnterBackground,
                         .willEnterForeground, .didBecomeActive],
             "virtual \(lockedSeconds)s lock preserves exactly one lifecycle sequence")
      check(timedState.playerPhase == .active && timedPlayer.running &&
            timedPlayer.displayLinkRunning, "virtual \(lockedSeconds)s unlock finishes active")
    }

    // Startup can cross a complete lock/unlock before Unity exists. Once
    // runEmbedded has already activated Unity, stale intermediate events must
    // not be replayed after the current active state.
    var startupFinished = UnityAvatarLifecycleState()
    for event in [UnityAvatarLifecycleEvent.willResignActive, .didEnterBackground,
                  .willEnterForeground, .didBecomeActive] {
      expect(startupFinished.receive(event), [], "pre-player events do not touch an engine")
    }
    expect(startupFinished.playerDidStart(fallbackHostPhase: .background), [],
           "latest observed active host wins over stale late-start fallback")
    check(startupFinished.hostPhase == .active && startupFinished.playerPhase == .active,
          "pre-player lock cycle reconciles to the final phase")

    // Missing callbacks must preserve the order Unity expects. In particular,
    // didBecomeActive alone cannot resume an engine with a stopped display link.
    var missed = UnityAvatarLifecycleState()
    var missedPlayer = RecordingUnityPlayer()
    missedPlayer.apply(missed.playerDidStart(fallbackHostPhase: .active))
    let directBackground = missed.receive(.didEnterBackground)
    expect(directBackground, [.willResignActive, .didEnterBackground],
           "missing resign is synthesized before background")
    missedPlayer.apply(directBackground)
    expect(missed.playerDidStart(fallbackHostPhase: .active), [],
           "repeated ready never overwrites a background engine phase")
    let directActive = missed.receive(.didBecomeActive)
    expect(directActive, [.willEnterForeground, .didBecomeActive],
           "missing foreground restarts display link before activation")
    missedPlayer.apply(directActive)
    check(missedPlayer.running && missedPlayer.displayLinkRunning,
          "missing-callback recovery leaves both engine and display link running")

    var initializing = UnityAvatarLifecycleState()
    expect(initializing.receive(.didEnterBackground), [],
           "background before engine readiness records host only")
    expect(initializing.synchronizePlayer(isReady: false, fallbackHostPhase: .active),
           [.didEnterBackground], "initializing engine stops its existing display link")
    expect(initializing.synchronizePlayer(isReady: false, fallbackHostPhase: .active), [],
           "initializing background does not stop the display link twice")
    check(initializing.playerPhase == nil,
          "pre-ready display-link control does not claim engine lifecycle delivery")
    expect(initializing.receive(.willEnterForeground), [],
           "foreground intent during initialization cannot activate the engine")
    expect(initializing.synchronizePlayer(isReady: false, fallbackHostPhase: .inactive),
           [.willEnterForeground], "unlock restarts the display link needed to finish initialization")
    expect(initializing.synchronizePlayer(isReady: false, fallbackHostPhase: .inactive), [],
           "initializing foreground resumes the display link only once")
    expect(initializing.receive(.didBecomeActive), [],
           "scene activation still cannot call an unready engine's didBecomeActive")
    expect(initializing.synchronizePlayer(isReady: false, fallbackHostPhase: .active), [],
           "pre-ready active synchronization does not cold-start Unity")
    expect(initializing.synchronizePlayer(isReady: true, fallbackHostPhase: .active), [],
           "late-ready active engine already has the runEmbedded active baseline")
    check(initializing.playerPhase == .active, "unlock during initialization reaches active readiness")
    expect(initializing.synchronizePlayer(isReady: true, fallbackHostPhase: .background), [],
           "repeated ready does not replay stale initialization transitions")

    var readyWhileLocked = UnityAvatarLifecycleState()
    expect(readyWhileLocked.synchronizePlayer(isReady: false, fallbackHostPhase: .background),
           [.didEnterBackground], "background fallback stops an initializing display link")
    check(readyWhileLocked.playerPhase == nil, "initial background fallback does not imply ready")
    expect(readyWhileLocked.synchronizePlayer(isReady: true, fallbackHostPhase: .active),
           [.willResignActive, .didEnterBackground],
           "ready while still locked pauses engine and stops its newly created display link")
    expect(readyWhileLocked.synchronizePlayer(isReady: true, fallbackHostPhase: .active), [],
           "duplicate ready while locked cannot poison explicit pause")
    expect(readyWhileLocked.receive(.didBecomeActive), [.willEnterForeground, .didBecomeActive],
           "ready-while-locked engine can later unlock without a foreground callback")

    for unlockEvent in [UnityAvatarLifecycleEvent.willEnterForeground, .didBecomeActive] {
      var readyDuringUnlock = UnityAvatarLifecycleState()
      _ = readyDuringUnlock.synchronizePlayer(isReady: false, fallbackHostPhase: .background)
      expect(readyDuringUnlock.receive(unlockEvent), [],
             "unlock event waits for first ready synchronization")
      let expected: [UnityAvatarLifecycleEvent] = unlockEvent == .willEnterForeground
        ? [.willEnterForeground, .willResignActive] : [.willEnterForeground]
      expect(readyDuringUnlock.synchronizePlayer(isReady: true, fallbackHostPhase: .active), expected,
             "ready during unlock restores display link before reconciling actual phase")
      expect(readyDuringUnlock.synchronizePlayer(isReady: true, fallbackHostPhase: .active), [],
             "initialization display-link marker is cleared on first ready")
      if unlockEvent == .willEnterForeground {
        expect(readyDuringUnlock.receive(.didBecomeActive), [.didBecomeActive],
               "foreground-inactive readiness waits for real scene activation")
      }
    }

    var relockedDuringInitialization = UnityAvatarLifecycleState()
    expect(relockedDuringInitialization.synchronizePlayer(isReady: false, fallbackHostPhase: .background),
           [.didEnterBackground], "initial pre-ready lock stops display link")
    _ = relockedDuringInitialization.receive(.willEnterForeground)
    expect(relockedDuringInitialization.synchronizePlayer(isReady: false, fallbackHostPhase: .inactive),
           [.willEnterForeground], "initial pre-ready unlock restarts display link")
    _ = relockedDuringInitialization.receive(.didEnterBackground)
    expect(relockedDuringInitialization.synchronizePlayer(isReady: false, fallbackHostPhase: .background),
           [.didEnterBackground], "relocking before ready stops display link again")
    expect(relockedDuringInitialization.synchronizePlayer(isReady: false, fallbackHostPhase: .background), [],
           "duplicate pre-ready relock remains idempotent")
    check(relockedDuringInitialization.playerPhase == nil,
          "several pre-ready lock transitions never consume engine readiness")

    // An independent, genuine engine pause must not be erased by OS lifecycle
    // recovery. This simulation models only the inspected Unity bookkeeping;
    // it is not a UIKit or UnityFramework integration test.
    var explicitState = UnityAvatarLifecycleState()
    var explicitPlayer = RecordingUnityPlayer(running: false)
    _ = explicitState.playerDidStart(fallbackHostPhase: .active)
    for event in [UnityAvatarLifecycleEvent.willResignActive, .didEnterBackground,
                  .willEnterForeground, .didBecomeActive] {
      explicitPlayer.apply(explicitState.receive(event))
    }
    check(explicitPlayer.explicitlyPaused && !explicitPlayer.running &&
          explicitPlayer.displayLinkRunning,
          "a real preexisting explicit pause remains owned by its original caller")

    // Discrimination check: bypassing the state gate really does poison the
    // simulated Unity bookkeeping, so the guarded repeated-lock assertions
    // above would detect a regression that forwards duplicate resign events.
    var ungatedPlayer = RecordingUnityPlayer()
    ungatedPlayer.apply([.willResignActive, .willResignActive,
                         .didEnterBackground, .willEnterForeground, .didBecomeActive])
    check(ungatedPlayer.explicitlyPaused && !ungatedPlayer.running,
          "ungated duplicate resign reproduces the inspected Unity pause failure")
    print("PASS: \(assertions) iOS Unity lifecycle assertions")
  }
}

private struct RecordingUnityPlayer {
  var running = true
  var explicitlyPaused = false
  var displayLinkRunning = true

  mutating func apply(_ events: [UnityAvatarLifecycleEvent]) {
    for event in events {
      switch event {
      case .willResignActive:
        explicitlyPaused = !running
        if !explicitlyPaused { running = false }
      case .didEnterBackground:
        displayLinkRunning = false
      case .willEnterForeground:
        displayLinkRunning = true
      case .didBecomeActive:
        if !explicitlyPaused { running = true }
      }
    }
  }
}
