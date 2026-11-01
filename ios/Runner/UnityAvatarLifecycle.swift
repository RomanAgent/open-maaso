/// Scene lifecycle ownership is independent of Flutter method-channel timing.
/// Unity's runEmbedded already enters the active state on its first launch.
enum UnityAvatarScenePhase {
  case active
  case inactive
  case background
}

enum UnityAvatarLifecycleEvent: String {
  case willResignActive
  case didEnterBackground
  case willEnterForeground
  case didBecomeActive
}

/// A renderer-ready flag does not acknowledge that its native view is attached.
/// Keep a requested view alive across inactive->active, fencing delayed work
/// when the owner detaches or starts another attachment lifecycle.
struct UnityAvatarAttachmentState {
  private var generation = 0
  private var requested = false
  private(set) var presentationId: String?

  var requestedGeneration: Int? { requested ? generation : nil }

  mutating func request(presentationId nextId: String? = nil) {
    if !requested || (nextId != nil && nextId != presentationId) {
      generation += 1
      requested = true
    }
    if let nextId { presentationId = nextId }
  }

  mutating func detach() {
    requested = false
    presentationId = nil
    generation += 1
  }

  func isCurrent(_ token: Int) -> Bool {
    requested && generation == token
  }
}

struct UnityAvatarLifecycleState {
  private(set) var hostPhase: UnityAvatarScenePhase?
  private(set) var playerPhase: UnityAvatarScenePhase?
  private var initializationDisplayLinkSuspended = false

  mutating func receive(_ event: UnityAvatarLifecycleEvent) -> [UnityAvatarLifecycleEvent] {
    switch event {
    case .willResignActive:
      if hostPhase == nil || hostPhase == .active {
        hostPhase = .inactive
      }
    case .didEnterBackground:
      hostPhase = .background
    case .willEnterForeground:
      if hostPhase == nil || hostPhase == .background {
        hostPhase = .inactive
      }
    case .didBecomeActive:
      hostPhase = .active
    }
    return reconcile()
  }

  mutating func synchronizePlayer(
    isReady: Bool,
    fallbackHostPhase: UnityAvatarScenePhase
  ) -> [UnityAvatarLifecycleEvent] {
    if hostPhase == nil {
      hostPhase = fallbackHostPhase
    }
    guard playerPhase == nil else { return [] }
    if isReady {
      let restoreDisplayLink: [UnityAvatarLifecycleEvent] =
        initializationDisplayLinkSuspended && hostPhase != .background
          ? [.willEnterForeground] : []
      initializationDisplayLinkSuspended = false
      return restoreDisplayLink + playerDidStart(fallbackHostPhase: fallbackHostPhase)
    }
    // These two Unity callbacks stop/start an existing display link without
    // starting the engine. Keep them separate from delivery of engine pause
    // and focus callbacks until graphics initialization has completed.
    if hostPhase == .background && !initializationDisplayLinkSuspended {
      initializationDisplayLinkSuspended = true
      return [.didEnterBackground]
    }
    if hostPhase != .background && initializationDisplayLinkSuspended {
      initializationDisplayLinkSuspended = false
      return [.willEnterForeground]
    }
    return []
  }

  mutating func playerDidStart(
    fallbackHostPhase: UnityAvatarScenePhase
  ) -> [UnityAvatarLifecycleEvent] {
    guard playerPhase == nil else { return [] }
    if hostPhase == nil {
      hostPhase = fallbackHostPhase
    }
    playerPhase = .active
    return reconcile()
  }

  private mutating func reconcile() -> [UnityAvatarLifecycleEvent] {
    guard let hostPhase, let playerPhase, hostPhase != playerPhase else {
      return []
    }
    let events: [UnityAvatarLifecycleEvent]
    switch (playerPhase, hostPhase) {
    case (.active, .inactive):
      events = [.willResignActive]
    case (.active, .background):
      events = [.willResignActive, .didEnterBackground]
    case (.inactive, .background):
      events = [.didEnterBackground]
    case (.background, .inactive):
      events = [.willEnterForeground]
    case (.background, .active):
      events = [.willEnterForeground, .didBecomeActive]
    case (.inactive, .active):
      events = [.didBecomeActive]
    default:
      events = []
    }
    self.playerPhase = hostPhase
    return events
  }
}
