import AppKit
import CoreImage
import CoreGraphics
import CoreVideo
import Darwin
import FlutterMacOS
import Foundation
import IOSurface
import QuartzCore
import Security

private enum UnityAgentSpacePayload {
  static let methods: Set<String> = [
    "enterAgentSpace", "leaveAgentSpace", "requestAgentSpaceMoveAtScreenPoint",
  ]
  private static let failureCodes: Set<String> = [
    "invalid_request", "unsupported_command", "space_renderer_failed",
    "session_retired", "space_busy", "space_transition_cancelled", "personal_room_unavailable",
    "personal_navigation_unavailable", "personal_camera_unavailable",
    "avatar_renderer_unavailable", "avatar_presentation_unavailable",
    "selected_avatar_unavailable", "avatar_floor_unavailable", "session_mismatch",
    "invalid_screen_point", "outside_walkable_floor", "path_blocked",
  ]

  static func isValidArguments(method: String, raw: Any?) -> Bool {
    guard methods.contains(method), let arguments = raw as? [String: Any] else {
      return false
    }
    let moving = method == "requestAgentSpaceMoveAtScreenPoint"
    let required: Set<String> = moving
      ? ["requestId", "sessionId", "x", "y"] : ["requestId", "sessionId"]
    let allowed = moving ? required
      : required.union(["animated", "viewportTop", "viewportBottom"])
    let actual = Set(arguments.keys)
    guard required.isSubset(of: actual), actual.isSubset(of: allowed),
          identifier(arguments["requestId"]), identifier(arguments["sessionId"])
    else { return false }
    if moving {
      return ["x", "y"].allSatisfy { boundedNumber(arguments[$0], maximum: 1) }
    }
    if actual.contains("animated") {
      guard let value = arguments["animated"] as? NSNumber,
            CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    }
    guard actual.contains("viewportTop") == actual.contains("viewportBottom")
    else { return false }
    return !actual.contains("viewportTop") || ["viewportTop", "viewportBottom"].allSatisfy {
      boundedNumber(arguments[$0], maximum: 0.45)
    }
  }

  private static func boundedNumber(_ raw: Any?, maximum: Double) -> Bool {
    guard let value = raw as? NSNumber,
          CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
    return value.doubleValue.isFinite && value.doubleValue >= 0 && value.doubleValue <= maximum
  }

  static func publicResult(_ raw: [String: Any]) -> [String: Any]? {
    guard Set(raw.keys) == ["method", "requestId", "sessionId", "ok", "code"],
          let method = raw["method"] as? String, methods.contains(method),
          identifier(raw["requestId"]), identifier(raw["sessionId"]),
          let ok = raw["ok"] as? NSNumber,
          CFGetTypeID(ok) == CFBooleanGetTypeID(), let code = raw["code"] as? String,
          ok.boolValue ? code.isEmpty : failureCodes.contains(code) else {
      return nil
    }
    return ["method": method, "requestId": raw["requestId"]!,
            "sessionId": raw["sessionId"]!, "ok": ok.boolValue, "code": code]
  }

  private static func identifier(_ raw: Any?) -> Bool {
    guard let value = raw as? String else { return false }
    guard let match = value.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) else { return false }
    return match.lowerBound == value.startIndex && match.upperBound == value.endIndex
  }
}

private enum UnityBackgroundTaskWorkPayload {
  static let commandMethod = "setBackgroundTaskWork"
  static let stateMethod = "backgroundTaskWorkState"
  private static let commandKeys: Set<String> = [
    "requestId", "sessionId", "phase", "loadRequestId", "sequence", "issuedAtEpochMs", "deadlineEpochMs",
  ]
  private static let resultKeys: Set<String> = [
    "method", "requestId", "sessionId", "phase", "loadRequestId", "sequence", "ok", "code",
  ]
  private static let stateKeys: Set<String> = [
    "method", "requestId", "sessionId", "loadRequestId", "phase", "furnitureId",
    "sceneId", "sequence", "workSessionId",
  ]
  private static let failureCodes: Set<String> = [
    "invalid_command", "deadline_expired", "model_stale", "stale_sequence",
    "session_ended", "session_mismatch", "authority_owned", "not_ready",
    "presentation_busy", "user_pose_owned", "work_unavailable", "mutation_failed",
  ]
  private static let phases: Set<String> = [
    "approaching", "aligning", "seated", "working", "lying", "rising", "standing",
  ]
  private static let furnitureIds: Set<String> = ["", "sofa", "chair", "desk", "bed"]

  static func isValidArguments(_ raw: Any?) -> Bool {
    guard let values = raw as? [String: Any], Set(values.keys) == commandKeys,
          identifier(values["requestId"]), session(values["sessionId"]),
          identifier(values["loadRequestId"]),
          let phase = values["phase"] as? String, ["start", "end"].contains(phase),
          positiveSafeInteger(values["sequence"]) != nil,
          let issued = positiveSafeInteger(values["issuedAtEpochMs"]),
          let deadline = positiveSafeInteger(values["deadlineEpochMs"]),
          deadline > issued, deadline - issued <= 10_000 else { return false }
    return true
  }

  static func publicResult(_ raw: [String: Any]) -> [String: Any]? {
    guard let method = raw["method"] as? String,
          identifier(raw["requestId"]), session(raw["sessionId"]),
          identifier(raw["loadRequestId"]),
          let sequence = positiveSafeInteger(raw["sequence"]) else { return nil }
    if method == commandMethod {
      guard Set(raw.keys) == resultKeys,
            let phase = raw["phase"] as? String, ["start", "end"].contains(phase),
            let ok = raw["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID(),
            let code = raw["code"] as? String, code.utf8.count <= 64,
            ok.boolValue ? code.isEmpty : failureCodes.contains(code) else { return nil }
      return ["method": method, "requestId": raw["requestId"]!, "sessionId": raw["sessionId"]!,
              "phase": phase, "loadRequestId": raw["loadRequestId"]!, "sequence": sequence,
              "ok": ok.boolValue, "code": code]
    }
    guard method == stateMethod, Set(raw.keys) == stateKeys,
          let phase = raw["phase"] as? String, phases.contains(phase),
          let furniture = raw["furnitureId"] as? String, furnitureIds.contains(furniture),
          phase == "standing" || !furniture.isEmpty,
          let scene = raw["sceneId"] as? String, !scene.isEmpty, scene.utf8.count <= 128,
          validFurnitureWorkSession(raw),
          raw["workSessionId"] is NSNull || raw["workSessionId"] as? String == "" ||
            raw["workSessionId"] as? String == raw["sessionId"] as? String else { return nil }
    return ["method": method, "requestId": raw["requestId"]!, "sessionId": raw["sessionId"]!,
            "loadRequestId": raw["loadRequestId"]!, "phase": phase, "furnitureId": furniture,
            "sceneId": scene, "sequence": sequence, "workSessionId": raw["workSessionId"]!]
  }

  static func validFurnitureWorkSession(_ raw: [String: Any]) -> Bool {
    guard let value = raw["workSessionId"], !(value is NSNull) else { return true }
    if value as? String == "" { return true }
    guard session(value), raw["furnitureId"] as? String == "desk",
          let phase = raw["phase"] as? String,
          ["approaching", "aligning", "working"].contains(phase) else { return false }
    return true
  }

  static func boundedWorkVersion(_ raw: Any?) -> Int64? {
    integer(raw, minimum: 0, maximum: 2_147_483_647)
  }

  private static func positiveSafeInteger(_ raw: Any?) -> Int64? {
    integer(raw, minimum: 1, maximum: 9_007_199_254_740_991)
  }

  private static func integer(_ raw: Any?, minimum: Int64, maximum: Int64) -> Int64? {
    guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite, value.doubleValue >= Double(minimum),
          value.doubleValue <= Double(maximum),
          value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
    return value.int64Value
  }

  private static func identifier(_ raw: Any?) -> Bool {
    guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 128,
          let match = value.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression)
    else { return false }
    return match.lowerBound == value.startIndex && match.upperBound == value.endIndex
  }

  private static func session(_ raw: Any?) -> Bool {
    guard let value = raw as? String, value.utf8.count == 64 else { return false }
    return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

final class MacOSUnityAvatarPortalBridge {
  private static let portalChannelName = "maaso/avatar_portal"
  private static let avatarChannelName = "maaso/unity_avatar"
  private static let maximumGeneration = 0x7fff_ffff
  private static let supportedTargetFps: Set<Int> = [24, 30, 60]
  private static let maximumAvatarJSONBytes = 32 * 1024
  private static let maximumAvatarArbiterJSONBytes = 256 * 1024
  private static let avatarMethods: Set<String> = [
    "prepareView", "loadAvatar",
    "setExpression", "setMouthOpen", "setGaze",
    "clearGaze", "startLipSync", "startVisemeTimeline", "stopLipSync", "playPrimitive",
    "syncSpeechPlaybackClock", "setConversationPhase",
    "playAnimationClip", "reactToScreenTap", "enterAgentSpace", "leaveAgentSpace",
    "requestAgentSpaceMoveAtScreenPoint", "transitionPresence", "transitionLoginDoorway",
    "setPhoneInteraction", "setLocalAvatarVisible", "setBackgroundTaskWork",
    "setHandIkTarget", "setBodyPose", "playMotion", "playMotionSequence",
    "setFraming", "setViewportSafeArea", "setWorldTimeOfDay", "setWorldCamera",
    "pause", "resume",
    "avatarArbiterCommand", "avatarArbiterReset",
  ]

  private let portalChannel: FlutterMethodChannel
  private let avatarChannel: FlutterMethodChannel
  private let textureRegistry: FlutterTextureRegistry
  private let texture = MacOSAvatarPortalTexture()
  private let desktopCompanionBridge: MacOSDesktopCompanionBridge
  private var textureID: Int64?
  private var session: MacOSUnitySidecarSession?
  private var sessionIdentity: UUID?
  private var activeGeneration = 0
  private var firstFrameGeneration = 0
  private var width = 0
  private var height = 0
  private var avatarReceiverReady = false

  init(
    registrar: FlutterPluginRegistrar,
    desktopCompanionBridge: MacOSDesktopCompanionBridge
  ) {
    self.desktopCompanionBridge = desktopCompanionBridge
    textureRegistry = registrar.textures
    portalChannel = FlutterMethodChannel(
      name: Self.portalChannelName,
      binaryMessenger: registrar.messenger)
    avatarChannel = FlutterMethodChannel(
      name: Self.avatarChannelName,
      binaryMessenger: registrar.messenger)
    portalChannel.setMethodCallHandler { [weak self] call, result in
      self?.handlePortal(call, result: result)
    }
    avatarChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleAvatar(call, result: result)
    }
  }

  deinit {
    releaseLease(reason: "bridgeDisposed", notifyFlutter: false)
    session?.stop()
    session = nil
  }

  private func handlePortal(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    let generation = arguments["generation"] as? Int ?? 0
    if call.method != "acquire",
       arguments["includeWorld"] != nil || arguments["viewportWidth"] != nil
        || arguments["viewportHeight"] != nil
    {
      result(FlutterError(
        code: "invalid_avatar_portal_viewport",
        message: "World viewport options are only valid when acquiring a portal.",
        details: nil))
      return
    }
    switch call.method {
    case "acquire":
      guard generation > 0, generation <= Self.maximumGeneration else {
        result(FlutterError(
          code: "invalid_avatar_portal_generation",
          message: "Avatar portal generation must be a positive 32-bit integer.",
          details: nil))
        return
      }
      let profile = arguments["profile"] as? String ?? "compactHigh"
      let targetFps = arguments["targetFps"] as? Int
        ?? Self.defaultTargetFps(for: profile)
      guard Self.supportedTargetFps.contains(targetFps) else {
        result(FlutterError(
          code: "invalid_avatar_portal_target_fps",
          message: "Avatar portal target FPS must be 24, 30, or 60.",
          details: nil))
        return
      }
      var includeWorld = false
      if let value = arguments["includeWorld"] {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
          result(FlutterError(
            code: "invalid_avatar_portal_viewport",
            message: "Avatar portal includeWorld must be a boolean.",
            details: nil))
          return
        }
        includeWorld = number.boolValue
      }
      let viewportWidth = Self.portalViewportDimension(arguments["viewportWidth"], maximum: 3840)
      let viewportHeight = Self.portalViewportDimension(arguments["viewportHeight"], maximum: 2160)
      guard includeWorld
        ? viewportWidth != nil && viewportHeight != nil
        : arguments["viewportWidth"] == nil && arguments["viewportHeight"] == nil
      else {
        result(FlutterError(
          code: "invalid_avatar_portal_viewport",
          message: "World viewport requires integer width 64...3840 and height 64...2160; avatar-only mode has no viewport options.",
          details: nil))
        return
      }
      acquire(
        generation: generation,
        profile: profile,
        targetFps: targetFps,
        includeWorld: includeWorld,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        result: result)
    case "suspend", "resume":
      guard generation == activeGeneration else {
        result(nil)
        return
      }
      session?.sendPortalCommand(
        method: call.method,
        generation: generation,
        profile: nil)
      result(nil)
    case "release":
      if generation <= 0 || generation == activeGeneration {
        releaseLease(reason: "released", notifyFlutter: false)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleAvatar(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard Self.avatarMethods.contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = Self.normalizedAvatarArguments(call.arguments),
          (!UnityAgentSpacePayload.methods.contains(call.method)
            || UnityAgentSpacePayload.isValidArguments(method: call.method, raw: arguments)),
          call.method != UnityBackgroundTaskWorkPayload.commandMethod
            || UnityBackgroundTaskWorkPayload.isValidArguments(arguments),
          !Self.isAvatarArbiterMethod(call.method)
            || Self.isValidAvatarArbiterArguments(
              method: call.method,
              arguments: arguments),
          let data = try? JSONSerialization.data(withJSONObject: arguments),
          data.count <= (Self.isAvatarArbiterMethod(call.method)
            ? Self.maximumAvatarArbiterJSONBytes
            : Self.maximumAvatarJSONBytes),
          let json = String(data: data, encoding: .utf8)
    else {
      result(FlutterError(
        code: Self.isAvatarArbiterMethod(call.method)
          ? "invalid_unity_avatar_arbiter_command"
          : "invalid_unity_avatar_command",
        message: Self.isAvatarArbiterMethod(call.method)
          ? "Unity Avatar arbiter command is invalid."
          : "Unity Avatar command arguments are invalid or too large.",
        details: nil))
      return
    }
    // The sidecar wire still has a 32 KiB arguments limit. A larger valid
    // arbiter payload must fail here instead of acknowledging a silent drop.
    guard data.count <= 32 * 1024 else {
      result(FlutterError(
        code: "unity_avatar_sidecar_payload_too_large",
        message: "Unity Avatar command exceeds the macOS sidecar limit.",
        details: nil))
      return
    }
    if (Self.isAvatarArbiterMethod(call.method) || UnityAgentSpacePayload.methods.contains(call.method)
        || call.method == UnityBackgroundTaskWorkPayload.commandMethod)
      && !avatarReceiverReady {
      result(FlutterError(
        code: "not_ready",
        message: "Unity Avatar renderer is not ready.",
        details: nil))
      return
    }
    do {
      let activeSession = try ensureSession()
      guard activeSession.sendAvatarCommand(method: call.method, json: json) else {
        result(FlutterError(
          code: "unity_avatar_sidecar_command_rejected",
          message: "Unity Avatar command could not be queued or sent.",
          details: nil))
        return
      }
      result(nil)
    } catch {
      NSLog("[MacOSUnityAvatarPortal] sidecar start failed: \(error)")
      result(FlutterError(
        code: "unity_avatar_sidecar_unavailable",
        message: "The bundled macOS Unity sidecar could not start.",
        details: String(describing: error)))
    }
  }

  private func acquire(
    generation: Int,
    profile: String,
    targetFps: Int,
    includeWorld: Bool = false,
    viewportWidth: Int? = nil,
    viewportHeight: Int? = nil,
    result: @escaping FlutterResult
  ) {
    guard var dimensions = Self.dimensions(for: profile) else {
      result(FlutterError(
        code: "invalid_avatar_portal_profile",
        message: "The Avatar portal profile is unsupported.",
        details: nil))
      return
    }
    if includeWorld {
      guard let viewportWidth, (64...3840).contains(viewportWidth),
            let viewportHeight, (64...2160).contains(viewportHeight)
      else {
        result(FlutterError(
          code: "invalid_avatar_portal_viewport",
          message: "World viewport dimensions are missing or outside the supported range.",
          details: nil))
        return
      }
      dimensions = (viewportWidth, viewportHeight)
    } else if viewportWidth != nil || viewportHeight != nil {
      result(FlutterError(
        code: "invalid_avatar_portal_viewport",
        message: "Avatar-only mode uses its profile dimensions.",
        details: nil))
      return
    }
    releaseLease(reason: "replaced", notifyFlutter: false)
    width = dimensions.width
    height = dimensions.height
    activeGeneration = generation
    firstFrameGeneration = 0

    let registeredTextureID = textureRegistry.register(texture)
    guard registeredTextureID > 0 else {
      activeGeneration = 0
      result(FlutterError(
        code: "avatar_portal_registration_failed",
        message: "Flutter rejected the macOS Avatar portal texture.",
        details: nil))
      return
    }
    textureID = registeredTextureID
    // Close the native pet gate before Unity can publish a full-scene surface.
    // Dart also hides the pet, but its separate channel call may arrive later.
    desktopCompanionBridge.setWorldCaptureActive(includeWorld)

    do {
      let activeSession = try ensureSession()
      activeSession.sendPortalCommand(
        method: "acquire",
        generation: generation,
        profile: profile,
        targetFps: targetFps,
        includeWorld: includeWorld,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight)
    } catch {
      releaseLease(reason: "sidecarUnavailable", notifyFlutter: false)
      result(FlutterError(
        code: "avatar_portal_sidecar_unavailable",
        message: "The bundled macOS Unity sidecar could not start.",
        details: String(describing: error)))
      return
    }

    result([
      "textureId": registeredTextureID,
      "width": width,
      "height": height,
      "generation": generation,
    ])
  }

  private func ensureSession() throws -> MacOSUnitySidecarSession {
    if let session { return session }
    let identity = UUID()
    let nextSession = try MacOSUnitySidecarSession(
      onAvatarReady: { [weak self] in
        guard let self, self.sessionIdentity == identity else { return }
        self.acceptAvatarReady()
      },
      onAvatarResult: { [weak self] payload in
        guard let self, self.sessionIdentity == identity else { return }
        self.acceptAvatarResult(payload)
      },
      onSurface: { [weak self] frame in
        guard let self, self.sessionIdentity == identity else { return }
        self.accept(frame: frame)
      },
      onEvent: { [weak self] name, eventGeneration in
        guard let self, self.sessionIdentity == identity else { return }
        self.accept(event: name, generation: eventGeneration)
      },
      onFailure: { [weak self] reason in
        guard let self, self.sessionIdentity == identity else { return }
        self.handleSessionFailure(reason)
      })
    session = nextSession
    sessionIdentity = identity
    do {
      try nextSession.start()
    } catch {
      session = nil
      sessionIdentity = nil
      nextSession.stop()
      throw error
    }
    return nextSession
  }

  private func acceptAvatarReady() {
    dispatchPrecondition(condition: .onQueue(.main))
    avatarReceiverReady = true
    avatarChannel.invokeMethod("ready", arguments: nil)
  }

  private func acceptAvatarResult(_ payload: [String: Any]) {
    dispatchPrecondition(condition: .onQueue(.main))
    if let method = payload["method"] as? String,
       method == UnityBackgroundTaskWorkPayload.commandMethod ||
         method == UnityBackgroundTaskWorkPayload.stateMethod {
      guard let result = UnityBackgroundTaskWorkPayload.publicResult(payload) else { return }
      avatarChannel.invokeMethod("commandResult", arguments: result)
      return
    }
    guard Self.isValidAvatarResult(payload) else { return }
    avatarChannel.invokeMethod("commandResult", arguments: payload)
  }

  private func accept(frame: MacOSUnitySurfaceFrame) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard frame.generation == activeGeneration,
          frame.width == width,
          frame.height == height
    else {
      return
    }
    desktopCompanionBridge.accept(frame: frame)
    guard
          let currentTextureID = textureID,
          texture.update(frame: frame)
    else {
      return
    }
    textureRegistry.textureFrameAvailable(currentTextureID)
    guard firstFrameGeneration != frame.generation else { return }
    firstFrameGeneration = frame.generation
    portalChannel.invokeMethod("event", arguments: [
      "type": "firstFrame",
      "generation": frame.generation,
      "textureId": currentTextureID,
      "width": frame.width,
      "height": frame.height,
    ])
  }

  private func accept(event name: String, generation: Int) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard generation == activeGeneration else { return }
    if name == "unityCommandFailed" || name == "portalControllerMissing" {
      handleSessionFailure(name)
    }
  }

  private func handleSessionFailure(_ reason: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    let generation = activeGeneration
    let failedSession = session
    session = nil
    sessionIdentity = nil
    failedSession?.stop()
    avatarReceiverReady = false
    releaseLease(reason: reason, notifyFlutter: false)
    avatarChannel.invokeMethod("unready", arguments: nil)
    if generation > 0 {
      portalChannel.invokeMethod("event", arguments: [
        "type": "released",
        "generation": generation,
        "reason": Self.boundedReason(reason),
      ])
    }
  }

  private func releaseLease(reason: String, notifyFlutter: Bool) {
    let generation = activeGeneration
    if generation > 0 {
      session?.sendPortalCommand(
        method: "release",
        generation: generation,
        profile: nil)
    }
    texture.clear()
    if let currentTextureID = textureID {
      textureRegistry.unregisterTexture(currentTextureID)
    }
    textureID = nil
    desktopCompanionBridge.clearAvatarFrame()
    activeGeneration = 0
    desktopCompanionBridge.setWorldCaptureActive(false)
    firstFrameGeneration = 0
    width = 0
    height = 0
    if notifyFlutter, generation > 0 {
      portalChannel.invokeMethod("event", arguments: [
        "type": "released",
        "generation": generation,
        "reason": Self.boundedReason(reason),
      ])
    }
  }

  private static func dimensions(for profile: String) -> (width: Int, height: Int)? {
    switch profile {
    case "desktopHigh": return (1024, 1792)
    case "compactLow": return (240, 416)
    case "compactBalanced": return (288, 496)
    case "compactHigh": return (320, 560)
    default: return nil
    }
  }

  private static func portalViewportDimension(_ value: Any?, maximum: Int) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)),
          number.doubleValue >= 64, number.doubleValue <= Double(maximum)
    else { return nil }
    return number.intValue
  }

  private static func defaultTargetFps(for profile: String) -> Int {
    profile == "compactLow" ? 24 : 30
  }

  private static func boundedReason(_ value: String) -> String {
    let normalized = value.isEmpty ? "sidecarFailure" : value
    return String(normalized.prefix(96))
  }

  private static func normalizedAvatarArguments(_ raw: Any?) -> [String: Any]? {
    guard let raw else { return [:] }
    guard let arguments = raw as? [String: Any],
          let normalized = normalizeJSON(arguments, depth: 0) as? [String: Any]
    else { return nil }
    return normalized
  }

  private static func normalizeJSON(_ value: Any, depth: Int) -> Any? {
    guard depth <= 6 else { return nil }
    if let dictionary = value as? [String: Any] {
      var result: [String: Any] = [:]
      for (key, child) in dictionary {
        guard !key.isEmpty, key.utf8.count <= 256,
              let normalized = normalizeJSON(child, depth: depth + 1)
        else { return nil }
        result[key] = normalized
      }
      return result
    }
    if let array = value as? [Any] {
      guard array.count <= 7200 else { return nil }
      var result: [Any] = []
      result.reserveCapacity(array.count)
      for child in array {
        guard let normalized = normalizeJSON(child, depth: depth + 1) else {
          return nil
        }
        result.append(normalized)
      }
      return result
    }
    if let string = value as? String {
      return string.utf8.count <= maximumAvatarArbiterJSONBytes ? string : nil
    }
    if value is NSNull { return value }
    if let number = value as? NSNumber {
      return number.doubleValue.isFinite ? number : nil
    }
    return nil
  }

  private static func isValidAvatarResult(_ payload: [String: Any]) -> Bool {
    if let method = payload["method"] as? String,
       method == UnityBackgroundTaskWorkPayload.commandMethod ||
         method == UnityBackgroundTaskWorkPayload.stateMethod {
      return UnityBackgroundTaskWorkPayload.publicResult(payload) != nil
    }
    if let method = payload["method"] as? String, UnityAgentSpacePayload.methods.contains(method) {
      return UnityAgentSpacePayload.publicResult(payload) != nil
    }
    if let method = payload["method"] as? String,
       isAvatarArbiterMethod(method) {
      return isValidAvatarArbiterResult(method: method, payload: payload)
    }
    let allowedMethods: Set<String> = [
      "transitionPresence", "transitionLoginDoorway", "setPhoneInteraction", "furnitureState",
      "loadAvatar",
    ]
    guard let method = payload["method"] as? String,
          allowedMethods.contains(method),
          let requestID = payload["requestId"] as? String,
          !requestID.isEmpty, requestID.utf8.count <= 256,
          payload["ok"] is Bool,
          normalizeJSON(payload, depth: 0) != nil
    else { return false }
    if method == "furnitureState" && !UnityBackgroundTaskWorkPayload.validFurnitureWorkSession(payload) {
      return false
    }
    if method == "loadAvatar", let version = payload["backgroundTaskWorkVersion"],
       UnityBackgroundTaskWorkPayload.boundedWorkVersion(version) == nil {
      return false
    }
    return true
  }

  private static let avatarArbiterChannels: Set<String> = [
    "mouth", "expression", "gaze", "bodyGesture", "framing",
  ]
  private static let avatarArbiterFailureCodes: Set<String> = [
    "deadline_expired", "owner_mismatch", "stale_ticket", "invalid_command",
    "mutation_failed", "reset_rejected",
  ]
  private static let avatarArbiterCommandKeys: Set<String> = [
    "protocolVersion", "requestId", "ticket", "rendererId", "ownerToken",
    "commitToken", "accountGeneration", "rendererGeneration", "channel",
    "fingerprint", "payloadJson", "payloadSha256", "deadlineEpochMs",
    "clearsChannel",
  ]
  private static let avatarArbiterResetKeys: Set<String> = [
    "protocolVersion", "requestId", "requirementId", "rendererId",
    "targetOwnerToken", "commitToken", "retiredAccountGeneration",
    "retiredRendererGeneration", "targetAccountGeneration",
    "targetRendererGeneration", "payloadJson", "payloadSha256",
    "deadlineEpochMs",
  ]

  private static func isAvatarArbiterMethod(_ method: String) -> Bool {
    method == "avatarArbiterCommand" || method == "avatarArbiterReset"
  }

  private static func isValidAvatarArbiterArguments(
    method: String,
    arguments: [String: Any]
  ) -> Bool {
    let command = method == "avatarArbiterCommand"
    let expected = command ? avatarArbiterCommandKeys : avatarArbiterResetKeys
    guard Set(arguments.keys) == expected,
          exactInteger(arguments["protocolVersion"], minimum: 1) == 1,
          identifier(arguments["requestId"], maximum: 96),
          identifier(arguments["rendererId"], maximum: 96),
          token(arguments["commitToken"]),
          lowerHex(arguments["payloadSha256"], length: 64),
          exactInteger(arguments["deadlineEpochMs"], minimum: 1) != nil,
          let payloadJSON = arguments["payloadJson"] as? String,
          !payloadJSON.isEmpty,
          payloadJSON.utf8.count <= maximumAvatarArbiterJSONBytes else {
      return false
    }
    if command {
      guard exactInteger(arguments["ticket"], minimum: 1) != nil,
            token(arguments["ownerToken"]),
            exactInteger(arguments["accountGeneration"], minimum: 0) != nil,
            exactInteger(arguments["rendererGeneration"], minimum: 0) != nil,
            let channel = arguments["channel"] as? String,
            avatarArbiterChannels.contains(channel),
            let clears = arguments["clearsChannel"] as? Bool,
            let fingerprint = arguments["fingerprint"] as? String else {
        return false
      }
      return clears ? fingerprint.isEmpty : lowerHex(fingerprint, length: 16)
    }
    guard exactInteger(arguments["requirementId"], minimum: 1) != nil,
          token(arguments["targetOwnerToken"]),
          exactInteger(arguments["retiredAccountGeneration"], minimum: 0) != nil,
          let retiredRenderer = exactInteger(
            arguments["retiredRendererGeneration"], minimum: 0),
          exactInteger(arguments["targetAccountGeneration"], minimum: 0) != nil,
          let targetRenderer = exactInteger(
            arguments["targetRendererGeneration"], minimum: 1),
          targetRenderer > retiredRenderer,
          payloadJSON == "{\"reset\":true}" else {
      return false
    }
    return true
  }

  private static func isValidAvatarArbiterResult(
    method: String,
    payload: [String: Any]
  ) -> Bool {
    let command = method == "avatarArbiterCommand"
    var expected = command ? avatarArbiterCommandKeys : avatarArbiterResetKeys
    expected.remove("payloadJson")
    expected.formUnion(["method", "ok", "code"])
    guard Set(payload.keys) == expected,
          exactInteger(payload["protocolVersion"], minimum: 1) == 1,
          identifier(payload["requestId"], maximum: 96),
          identifier(payload["rendererId"], maximum: 96),
          token(payload["commitToken"]),
          lowerHex(payload["payloadSha256"], length: 64),
          exactInteger(payload["deadlineEpochMs"], minimum: 1) != nil,
          let ok = payload["ok"] as? Bool,
          let code = payload["code"] as? String,
          (ok ? code.isEmpty : avatarArbiterFailureCodes.contains(code)) else {
      return false
    }
    if command {
      guard exactInteger(payload["ticket"], minimum: 1) != nil,
            token(payload["ownerToken"]),
            exactInteger(payload["accountGeneration"], minimum: 0) != nil,
            exactInteger(payload["rendererGeneration"], minimum: 0) != nil,
            let channel = payload["channel"] as? String,
            avatarArbiterChannels.contains(channel),
            let clears = payload["clearsChannel"] as? Bool,
            let fingerprint = payload["fingerprint"] as? String,
            clears ? fingerprint.isEmpty : lowerHex(fingerprint, length: 16) else {
        return false
      }
      return true
    }
    guard exactInteger(payload["requirementId"], minimum: 1) != nil,
          token(payload["targetOwnerToken"]),
          exactInteger(payload["retiredAccountGeneration"], minimum: 0) != nil,
          let retiredRenderer = exactInteger(
            payload["retiredRendererGeneration"], minimum: 0),
          exactInteger(payload["targetAccountGeneration"], minimum: 0) != nil,
          let targetRenderer = exactInteger(
            payload["targetRendererGeneration"], minimum: 1),
          targetRenderer > retiredRenderer else {
      return false
    }
    return true
  }

  private static func exactInteger(
    _ raw: Any?,
    minimum: Int64
  ) -> Int64? {
    guard let number = raw as? NSNumber,
          String(cString: number.objCType) != "c",
          number.doubleValue.isFinite,
          number.doubleValue >= Double(minimum),
          number.doubleValue <= 9_007_199_254_740_991,
          number.doubleValue.rounded(.towardZero) == number.doubleValue else {
      return nil
    }
    return number.int64Value
  }

  private static func identifier(_ raw: Any?, maximum: Int) -> Bool {
    guard let value = raw as? String,
          !value.isEmpty, value.utf8.count <= maximum else { return false }
    return value.range(
      of: "^[A-Za-z0-9][A-Za-z0-9_.:-]*$",
      options: .regularExpression) != nil
  }

  private static func token(_ raw: Any?) -> Bool {
    guard let value = raw as? String else { return false }
    return value.range(
      of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
  }

  private static func lowerHex(_ raw: Any?, length: Int) -> Bool {
    guard let value = raw as? String, value.utf8.count == length else {
      return false
    }
    return value.range(
      of: "^[a-f0-9]{\(length)}$", options: .regularExpression) != nil
  }
}

/// Hosts the macOS desktop pet in a native, engine-independent panel while the
/// Flutter application window remains a normal application surface.
///
/// The panel deliberately reuses the IOSurface produced by the existing Unity
/// sidecar. It does not create another Flutter engine or avatar renderer.
final class MacOSDesktopCompanionBridge {
  private static let channelName = "maaso/desktop_companion"
  private static let maximumMenuItems = 24
  private static let maximumMenuIDLength = 128
  private static let maximumMenuLabelLength = 80
  private static let maximumBubbleLength = 420

  private let channel: FlutterMethodChannel
  private let surfaceRenderer = MacOSDesktopPetSurfaceRenderer()
  private var panel: MacOSDesktopPetPanel?
  private var worldCaptureActive = false
  private var menuConfiguration = MacOSDesktopPetMenuConfiguration.default
  private var presentationConfiguration =
    MacOSDesktopCompanionPresentationConfiguration.default

  var isPetVisible: Bool {
    panel?.isVisible == true
  }

  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    panel?.dispose()
  }

  fileprivate func accept(frame: MacOSUnitySurfaceFrame) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !worldCaptureActive else { return }
    guard let image = surfaceRenderer.makeImage(frame: frame) else {
      clearAvatarFrame()
      return
    }
    ensurePanel().setAvatarImage(image)
  }

  func clearAvatarFrame() {
    dispatchPrecondition(condition: .onQueue(.main))
    panel?.clearAvatarImage()
  }

  fileprivate func setWorldCaptureActive(_ active: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    worldCaptureActive = active
    guard active else { return }
    panel?.hidePanel()
    panel?.clearAvatarImage()
  }

  private func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    if worldCaptureActive && call.method == "show" {
      result(FlutterError(
        code: "desktop_companion_world_capture_active",
        message: "The desktop pet cannot display a full-scene portal surface.",
        details: nil))
      return
    }
    switch call.method {
    case "configurePresentation":
      guard let configuration =
        MacOSDesktopCompanionPresentationConfiguration.parse(call.arguments)
      else {
        result(FlutterError(
          code: "invalid_desktop_companion_presentation",
          message: "Desktop companion presentation settings are invalid.",
          details: nil))
        return
      }
      presentationConfiguration = configuration
      panel?.applyPresentation(configuration)
      result(nil)
    case "configureMenu":
      guard let configuration = Self.parseMenuConfiguration(call.arguments)
      else {
        result(FlutterError(
          code: "invalid_desktop_companion_menu",
          message: "Desktop companion menu entries are invalid.",
          details: nil))
        return
      }
      menuConfiguration = configuration
      panel?.menuConfiguration = configuration
      result(nil)
    case "show":
      guard let arguments = call.arguments as? [String: Any],
            Set(arguments.keys) == ["interactionGeneration"],
            let generationNumber = arguments["interactionGeneration"] as? NSNumber,
            CFGetTypeID(generationNumber) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(generationNumber),
            generationNumber.doubleValue.isFinite,
            generationNumber.doubleValue.rounded(.towardZero)
              == generationNumber.doubleValue,
            generationNumber.int64Value >= 1,
            generationNumber.int64Value <= Int64(Int32.max)
      else {
        result(FlutterError(
          code: "invalid_desktop_companion_generation",
          message: "Desktop companion interaction generation is invalid.",
          details: nil))
        return
      }
      ensurePanel().showPanel(
        interactionGeneration: Int(generationNumber.int64Value))
      result(nil)
    case "hide":
      panel?.hidePanel()
      result(nil)
    case "showBubble":
      let arguments = call.arguments as? [String: Any]
      let text = arguments?["text"] as? String ?? ""
      let bounded = String(text.prefix(Self.maximumBubbleLength))
      if bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        panel?.clearBubble()
      } else {
        ensurePanel().showBubble(text: bounded)
      }
      result(nil)
    case "clearBubble":
      panel?.clearBubble()
      result(nil)
    case "dispose":
      panel?.dispose()
      panel = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensurePanel() -> MacOSDesktopPetPanel {
    if let panel { return panel }
    let newPanel = MacOSDesktopPetPanel(
      menuConfiguration: menuConfiguration,
      presentationConfiguration: presentationConfiguration,
      onMenuSelected: { [weak self] itemID in
        self?.channel.invokeMethod(
          "menuSelected",
          arguments: ["id": itemID])
      },
      onCommand: { [weak self] commandID in
        self?.channel.invokeMethod(
          "command",
          arguments: ["id": commandID])
      },
      onGazeChanged: { [weak self] gaze in
        guard let self else { return }
        if let gaze {
          self.channel.invokeMethod("gazeChanged", arguments: [
            "active": true,
            "x": gaze.x,
            "y": gaze.y,
          ])
        } else {
          self.channel.invokeMethod("gazeChanged", arguments: [
            "active": false,
          ])
        }
      },
      onAvatarInteraction: { [weak self] interaction in
        self?.channel.invokeMethod(
          "avatarInteraction",
          arguments: [
            "version": 1,
            "type": "tap",
            "normalizedX": Double(interaction.normalizedX),
            "normalizedY": Double(interaction.normalizedY),
            "region": interaction.region.rawValue,
            "generation": interaction.generation,
            "timestampMs": interaction.timestampMs,
          ])
      })
    panel = newPanel
    return newPanel
  }

  private static func parseMenuConfiguration(
    _ rawArguments: Any?
  ) -> MacOSDesktopPetMenuConfiguration? {
    let arguments = rawArguments as? [String: Any]
    let rawItems = arguments?["items"] as? [Any] ?? rawArguments as? [Any] ?? []
    guard rawItems.count <= maximumMenuItems else { return nil }

    var seenIDs: Set<String> = []
    var items: [MacOSDesktopPetMenuEntry] = []
    items.reserveCapacity(rawItems.count)
    for rawItem in rawItems {
      guard let item = rawItem as? [String: Any],
            let rawID = item["id"] as? String,
            let rawLabel = item["label"] as? String
      else { return nil }
      let itemID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
      let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !itemID.isEmpty,
            itemID.utf8.count <= maximumMenuIDLength,
            !label.isEmpty,
            label.utf8.count <= maximumMenuLabelLength,
            seenIDs.insert(itemID).inserted
      else { return nil }
      items.append(MacOSDesktopPetMenuEntry(
        id: itemID,
        label: label,
        isEnabled: item["enabled"] as? Bool ?? true))
    }

    func label(_ key: String, fallback: String) -> String {
      guard let rawValue = arguments?[key] as? String else { return fallback }
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, value.utf8.count <= maximumMenuLabelLength else {
        return fallback
      }
      return value
    }

    return MacOSDesktopPetMenuConfiguration(
      entries: items,
      openAppLabel: label("openAppLabel", fallback: "Open Maaso"),
      hidePetLabel: label("hidePetLabel", fallback: "Hide Desktop Pet"),
      quitLabel: label("quitLabel", fallback: "Quit Maaso"))
  }
}

private enum MacOSDesktopAvatarTapRegion: String {
  case head
  case torso
  case leftSide
  case rightSide
  case feet
  case avatar
}

private struct MacOSDesktopAvatarInteraction {
  let normalizedX: CGFloat
  let normalizedY: CGFloat
  let region: MacOSDesktopAvatarTapRegion
  let generation: Int
  let timestampMs: Int
}

private enum MacOSDesktopPetSpatialAttachmentKind: String {
  case workAreaEdge
  case windowTop
}

private enum MacOSDesktopPetSpatialEdge: String {
  case top
  case bottom
  case left
  case right
}

private struct MacOSDesktopPetSpatialAttachment: Equatable {
  private static let keys: Set<String> = ["kind", "targetId", "edge"]
  private static let maximumIDLength = 256

  let kind: MacOSDesktopPetSpatialAttachmentKind
  let targetID: String
  let edge: MacOSDesktopPetSpatialEdge

  static func parse(_ rawValue: Any?) -> MacOSDesktopPetSpatialAttachment? {
    guard let value = rawValue as? [String: Any],
          Set(value.keys) == keys,
          let kindValue = value["kind"] as? String,
          let kind = MacOSDesktopPetSpatialAttachmentKind(rawValue: kindValue),
          let targetID = value["targetId"] as? String,
          !targetID.isEmpty,
          targetID.utf8.count <= maximumIDLength,
          targetID == targetID.trimmingCharacters(in: .whitespacesAndNewlines),
          let edgeValue = value["edge"] as? String,
          let edge = MacOSDesktopPetSpatialEdge(rawValue: edgeValue),
          kind != .windowTop || edge == .top
    else { return nil }
    return MacOSDesktopPetSpatialAttachment(
      kind: kind,
      targetID: targetID,
      edge: edge)
  }

  var dictionary: [String: Any] {
    [
      "kind": kind.rawValue,
      "targetId": targetID,
      "edge": edge.rawValue,
    ]
  }
}

private struct MacOSDesktopPetSpatialStateV1 {
  private static let baseKeys: Set<String> = [
    "version", "monitorId", "normalizedX", "normalizedY",
  ]
  private static let allKeys = baseKeys.union(["attachment"])
  private static let maximumMonitorIDLength = 256

  let monitorID: String
  let normalizedX: CGFloat
  let normalizedY: CGFloat
  let attachment: MacOSDesktopPetSpatialAttachment?

  static func parse(_ rawValue: Any?) -> MacOSDesktopPetSpatialStateV1? {
    guard let value = rawValue as? [String: Any] else { return nil }
    let keys = Set(value.keys)
    guard keys == baseKeys || keys == allKeys,
          let versionNumber = value["version"] as? NSNumber,
          CFGetTypeID(versionNumber) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(versionNumber),
          versionNumber.intValue == 1,
          let monitorID = value["monitorId"] as? String,
          !monitorID.isEmpty,
          monitorID.utf8.count <= maximumMonitorIDLength,
          monitorID == monitorID.trimmingCharacters(in: .whitespacesAndNewlines),
          let normalizedXNumber = value["normalizedX"] as? NSNumber,
          CFGetTypeID(normalizedXNumber) != CFBooleanGetTypeID(),
          normalizedXNumber.doubleValue.isFinite,
          normalizedXNumber.doubleValue >= 0,
          normalizedXNumber.doubleValue <= 1,
          let normalizedYNumber = value["normalizedY"] as? NSNumber,
          CFGetTypeID(normalizedYNumber) != CFBooleanGetTypeID(),
          normalizedYNumber.doubleValue.isFinite,
          normalizedYNumber.doubleValue >= 0,
          normalizedYNumber.doubleValue <= 1
    else { return nil }

    let attachment: MacOSDesktopPetSpatialAttachment?
    if keys.contains("attachment") {
      guard let parsed = MacOSDesktopPetSpatialAttachment.parse(
        value["attachment"])
      else { return nil }
      attachment = parsed
    } else {
      attachment = nil
    }
    return MacOSDesktopPetSpatialStateV1(
      monitorID: monitorID,
      normalizedX: CGFloat(normalizedXNumber.doubleValue),
      normalizedY: CGFloat(normalizedYNumber.doubleValue),
      attachment: attachment)
  }

  var dictionary: [String: Any] {
    var value: [String: Any] = [
      "version": 1,
      "monitorId": monitorID,
      "normalizedX": Double(normalizedX),
      "normalizedY": Double(normalizedY),
    ]
    if let attachment {
      value["attachment"] = attachment.dictionary
    }
    return value
  }
}

private struct MacOSDesktopPetMonitor {
  let screen: NSScreen
  let displayID: CGDirectDisplayID
  let id: String
  let frame: NSRect
  let visibleFrame: NSRect
}

private struct MacOSDesktopPetSnapCandidate {
  let attachment: MacOSDesktopPetSpatialAttachment
  let origin: NSPoint
  let distance: CGFloat
}

private struct MacOSDesktopPetForeignWindow {
  let id: String
  let frame: NSRect
}

private struct MacOSDesktopPetMenuEntry {
  let id: String
  let label: String
  let isEnabled: Bool
}

private struct MacOSDesktopPetMenuConfiguration {
  let entries: [MacOSDesktopPetMenuEntry]
  let openAppLabel: String
  let hidePetLabel: String
  let quitLabel: String

  static let `default` = MacOSDesktopPetMenuConfiguration(
    entries: [],
    openAppLabel: "Open Maaso",
    hidePetLabel: "Hide Desktop Pet",
    quitLabel: "Quit Maaso")
}

private struct MacOSDesktopCompanionPresentationConfiguration {
  private static let keys: Set<String> = [
    "version", "quality", "targetFps", "visualScale", "alwaysOnTop",
    "snapEnabled", "snapAcquireDistance", "snapReleaseDistance",
  ]
  private static let supportedVisualScales: Set<Double> = [
    1.2, 1.8, 2.4, 3.0,
  ]

  let quality: String
  let targetFps: Int
  let visualScale: CGFloat
  let alwaysOnTop: Bool
  let snapEnabled: Bool
  let snapAcquireDistance: CGFloat
  let snapReleaseDistance: CGFloat

  static let `default` = MacOSDesktopCompanionPresentationConfiguration(
    quality: "crisp",
    targetFps: 30,
    visualScale: 1.8,
    alwaysOnTop: true,
    snapEnabled: false,
    snapAcquireDistance: 24,
    snapReleaseDistance: 40)

  static func parse(_ rawArguments: Any?)
    -> MacOSDesktopCompanionPresentationConfiguration?
  {
    guard let arguments = rawArguments as? [String: Any],
          Set(arguments.keys) == keys,
          arguments["version"] as? Int == 1,
          let quality = arguments["quality"] as? String,
          ["eco", "balanced", "crisp"].contains(quality),
          let targetFps = arguments["targetFps"] as? Int,
          [24, 30, 60].contains(targetFps),
          let visualScaleNumber = arguments["visualScale"] as? NSNumber,
          CFGetTypeID(visualScaleNumber) != CFBooleanGetTypeID(),
          visualScaleNumber.doubleValue.isFinite,
          supportedVisualScales.contains(visualScaleNumber.doubleValue),
          let alwaysOnTopNumber = arguments["alwaysOnTop"] as? NSNumber,
          CFGetTypeID(alwaysOnTopNumber) == CFBooleanGetTypeID(),
          let snapEnabledNumber = arguments["snapEnabled"] as? NSNumber,
          CFGetTypeID(snapEnabledNumber) == CFBooleanGetTypeID(),
          let snapAcquireNumber = arguments["snapAcquireDistance"] as? NSNumber,
          CFGetTypeID(snapAcquireNumber) != CFBooleanGetTypeID(),
          snapAcquireNumber.doubleValue.isFinite,
          snapAcquireNumber.doubleValue >= 4,
          snapAcquireNumber.doubleValue <= 160,
          let snapReleaseNumber = arguments["snapReleaseDistance"] as? NSNumber,
          CFGetTypeID(snapReleaseNumber) != CFBooleanGetTypeID(),
          snapReleaseNumber.doubleValue.isFinite,
          snapReleaseNumber.doubleValue >= 4,
          snapReleaseNumber.doubleValue <= 240,
          snapReleaseNumber.doubleValue >= snapAcquireNumber.doubleValue
    else { return nil }
    return MacOSDesktopCompanionPresentationConfiguration(
      quality: quality,
      targetFps: targetFps,
      visualScale: CGFloat(visualScaleNumber.doubleValue),
      alwaysOnTop: alwaysOnTopNumber.boolValue,
      snapEnabled: snapEnabledNumber.boolValue,
      snapAcquireDistance: CGFloat(snapAcquireNumber.doubleValue),
      snapReleaseDistance: CGFloat(snapReleaseNumber.doubleValue))
  }
}

private final class MacOSDesktopPetPanel: NSPanel {
  private static let basePanelSize = NSSize(width: 300, height: 420)
  private static let baseAvatarWidth: CGFloat = 160
  private static let baseAvatarHeight: CGFloat = 280
  private static let legacyStoredFrameKey = "maaso.desktopCompanion.panelFrame"
  private static let spatialStateKey =
    "maaso.desktopCompanion.spatialStateV1"
  private static let gazeInterval: TimeInterval = 1.0 / 24.0
  private static let gazeDeltaThreshold = 0.012
  private static let maximumTapDuration: TimeInterval = 0.5
  private static let baseDragThreshold: CGFloat = 6
  private static let maximumTimestampMs = 9_007_199_254_740_991.0
  private static let minimumForeignWindowWidth: CGFloat = 120
  private static let minimumForeignWindowHeight: CGFloat = 80
  private static let minimumForeignWindowAlpha = 0.05
  private static let excludedForeignWindowOwners: Set<String> = [
    "Dock", "Window Server",
  ]
  private static let excludedForeignWindowOwnerPrefixes = [
    "maaso", "masso_avatar",
  ]

  private struct PointerGesture {
    let downUptime: TimeInterval
    let mouseStart: NSPoint
    let mouseDownEvent: NSEvent
  }

  private let petContentView: MacOSDesktopPetContentView
  private let onMenuSelected: (String) -> Void
  private let onCommand: (String) -> Void
  private let onGazeChanged: (CGPoint?) -> Void
  private let onAvatarInteraction: (MacOSDesktopAvatarInteraction) -> Void
  private var gazeTimer: Timer?
  private var localMouseMoveMonitor: Any?
  private var globalMouseMoveMonitor: Any?
  private var lastGaze: CGPoint?
  private var isDraggingPet = false
  private var pointerGesture: PointerGesture?
  private var dragCompletionTimer: Timer?
  private var dragPanelSizeBeforeTracking: NSSize?
  private var visibilityGeneration = 0
  private var spatialState: MacOSDesktopPetSpatialStateV1?
  private var presentationConfiguration:
    MacOSDesktopCompanionPresentationConfiguration

  var menuConfiguration: MacOSDesktopPetMenuConfiguration

  init(
    menuConfiguration: MacOSDesktopPetMenuConfiguration,
    presentationConfiguration: MacOSDesktopCompanionPresentationConfiguration,
    onMenuSelected: @escaping (String) -> Void,
    onCommand: @escaping (String) -> Void,
    onGazeChanged: @escaping (CGPoint?) -> Void,
    onAvatarInteraction: @escaping (MacOSDesktopAvatarInteraction) -> Void
  ) {
    self.menuConfiguration = menuConfiguration
    self.presentationConfiguration = presentationConfiguration
    self.onMenuSelected = onMenuSelected
    self.onCommand = onCommand
    self.onGazeChanged = onGazeChanged
    self.onAvatarInteraction = onAvatarInteraction
    spatialState = Self.loadSpatialState()
    let initialSize = Self.panelSize(
      visualScale: presentationConfiguration.visualScale)
    petContentView = MacOSDesktopPetContentView(
      frame: NSRect(origin: .zero, size: initialSize),
      visualScale: presentationConfiguration.visualScale)
    super.init(
      contentRect: NSRect(origin: .zero, size: initialSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)

    contentView = petContentView
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    level = Self.windowLevel(alwaysOnTop: presentationConfiguration.alwaysOnTop)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isMovable = false
    isMovableByWindowBackground = false
    animationBehavior = .none
    ignoresMouseEvents = true
    isExcludedFromWindowsMenu = true
    setFrame(
      Self.restoredOrInitialFrame(
        panelSize: initialSize,
        spatialState: spatialState),
      display: false)
    UserDefaults.standard.removeObject(forKey: Self.legacyStoredFrameKey)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenParametersDidChange(_:)),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil)
    if spatialState != nil {
      restoreSpatialPlacement(panelSize: initialSize)
    } else {
      persistSpatialState(attachment: nil)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func orderFrontRegardless() {
    guard !MaasoApplicationExitPresentation.isExiting else {
      super.orderOut(nil)
      return
    }
    super.orderFrontRegardless()
  }

  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    guard place == .out || !MaasoApplicationExitPresentation.isExiting else {
      super.order(.out, relativeTo: 0)
      return
    }
    super.order(place, relativeTo: otherWin)
  }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    // AppKit otherwise pins the top of this tall transparent panel to the
    // menu bar, overriding our avatar-only bounds whenever it is visible.
    // Drag/drop/restore already clamp the visible avatar.
    frameRect
  }

  override func close() {
    hidePanel()
  }

  func showPanel(interactionGeneration: Int) {
    visibilityGeneration = interactionGeneration
    cancelPointerGesture()
    restoreSpatialPlacement(panelSize: frame.size)
    orderFrontRegardless()
    startGazeTracking()
    updateGaze()
  }

  func hidePanel() {
    cancelPointerGesture()
    guard isVisible || gazeTimer != nil else { return }
    orderOut(nil)
    clearBubble()
    stopGazeTracking()
  }

  func dispose() {
    NotificationCenter.default.removeObserver(
      self,
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil)
    hidePanel()
    clearAvatarImage()
  }

  func setAvatarImage(_ image: CGImage) {
    petContentView.setAvatarImage(image)
    updateMousePassthrough()
  }

  func clearAvatarImage() {
    petContentView.clearAvatarImage()
    updateMousePassthrough()
  }

  func showBubble(text: String) {
    petContentView.showBubble(text: text)
  }

  func clearBubble() {
    petContentView.clearBubble()
  }

  func applyPresentation(
    _ configuration: MacOSDesktopCompanionPresentationConfiguration
  ) {
    cancelPointerGesture()
    let retainedAttachment = configuration.snapEnabled
      ? spatialState?.attachment
      : nil
    persistSpatialState(attachment: retainedAttachment)
    presentationConfiguration = configuration
    level = Self.windowLevel(alwaysOnTop: configuration.alwaysOnTop)
    petContentView.applyVisualScale(configuration.visualScale)
    let nextSize = Self.panelSize(visualScale: configuration.visualScale)
    restoreSpatialPlacement(panelSize: nextSize)
    updateMousePassthrough()
    updateGaze()
  }

  func beginDragging(with event: NSEvent) {
    guard event.type == .leftMouseDown else { return }
    cancelPointerGesture()
    guard isVisible, visibilityGeneration > 0 else { return }
    let point = petContentView.convert(event.locationInWindow, from: nil)
    guard petContentView.containsVisibleAvatar(at: point) else { return }
    pointerGesture = PointerGesture(
      downUptime: ProcessInfo.processInfo.systemUptime,
      mouseStart: convertPoint(toScreen: event.locationInWindow),
      mouseDownEvent: event)
    isDraggingPet = false
    ignoresMouseEvents = false
  }

  func continueDragging() {
    guard let gesture = pointerGesture, !isDraggingPet else { return }
    guard isVisible, visibilityGeneration > 0 else {
      cancelPointerGesture()
      return
    }
    // A queued drag event can arrive after the physical button was released.
    guard NSEvent.pressedMouseButtons & 1 != 0 else {
      cancelPointerGesture()
      return
    }
    let mouse = NSEvent.mouseLocation
    let movement = hypot(
      mouse.x - gesture.mouseStart.x,
      mouse.y - gesture.mouseStart.y)
    guard movement > dragThreshold else { return }
    isDraggingPet = true
    // Window Server applies its own top-edge limit, even when AppKit's
    // constrainFrameRect is overridden. Exclude unused bubble headroom while
    // dragging; the avatar remains the same size at the same bottom origin.
    dragPanelSizeBeforeTracking = frame.size
    setFrame(
      NSRect(origin: frame.origin, size: NSSize(
        width: frame.width,
        height: Self.visibleAvatarHeight(panelSize: frame.size))),
      display: true)
    // setFrame updates the window before Core Animation commits its backing.
    // Submit the resized layer tree before Window Server takes over, otherwise
    // its first drag frame still presents the old, taller backing and jumps.
    petContentView.layoutSubtreeIfNeeded()
    CATransaction.flush()
    isMovable = true
    // Window Server owns movement, independently of Flutter/avatar rendering.
    // performDrag returns immediately and may consume mouseUp, so also observe
    // the physical left button. Never write frame origins during this drag.
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
      guard let self, self.dragCompletionTimer === timer else {
        timer.invalidate()
        return
      }
      self.finishSystemDragIfReleased()
    }
    dragCompletionTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    performDrag(with: gesture.mouseDownEvent)
  }

  private func finishSystemDragIfReleased() {
    guard isDraggingPet, pointerGesture != nil,
          NSEvent.pressedMouseButtons & 1 == 0 else { return }
    let canDrop = isVisible && visibilityGeneration > 0
    cancelPointerGesture()
    if canDrop { finishSpatialDrop() }
  }

  func endDragging(with event: NSEvent) {
    guard let gesture = pointerGesture else {
      cancelPointerGesture()
      return
    }
    let mouse = NSEvent.mouseLocation
    let movement = hypot(
      mouse.x - gesture.mouseStart.x,
      mouse.y - gesture.mouseStart.y)
    let duration = ProcessInfo.processInfo.systemUptime - gesture.downUptime
    let didDrag = isDraggingPet
    let tapLocation = petContentView.convert(event.locationInWindow, from: nil)
    let generation = visibilityGeneration

    cancelPointerGesture()
    if didDrag {
      if isVisible && generation > 0 {
        finishSpatialDrop()
      }
      return
    }

    guard duration >= 0,
          duration <= Self.maximumTapDuration,
          movement <= dragThreshold,
          generation > 0,
          isVisible,
          let semanticTap = petContentView.semanticTap(at: tapLocation)
    else { return }
    onAvatarInteraction(MacOSDesktopAvatarInteraction(
      normalizedX: semanticTap.normalizedX,
      normalizedY: semanticTap.normalizedY,
      region: semanticTap.region,
      generation: generation,
      timestampMs: Self.monotonicTimestampMs()))
  }

  func cancelPointerGesture() {
    dragCompletionTimer?.invalidate()
    dragCompletionTimer = nil
    // Physical mouse-up can precede AppKit's last window-move notification.
    // Read our Window Server position before changing native tracking/size;
    // restoring from a stale frame would move a quick drag back to its old spot.
    let trackedOrigin = dragPanelSizeBeforeTracking == nil
      ? nil : currentWindowServerFrame()?.origin
    isMovable = false
    if let normalSize = dragPanelSizeBeforeTracking {
      dragPanelSizeBeforeTracking = nil
      let restoredOrigin = trackedOrigin ?? frame.origin
      setFrame(NSRect(origin: restoredOrigin, size: normalSize), display: isVisible)
      petContentView.layoutSubtreeIfNeeded()
      CATransaction.flush()
    }
    isDraggingPet = false
    pointerGesture = nil
    updateMousePassthrough()
  }

  private func currentWindowServerFrame() -> NSRect? {
    guard windowNumber > 0,
          let windowID = CGWindowID(exactly: windowNumber),
          let windows = CGWindowListCopyWindowInfo(
            .optionIncludingWindow, windowID) as? [[String: Any]],
          let info = windows.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
          }),
          let bounds = info[kCGWindowBounds as String] as? NSDictionary,
          let quartzFrame = CGRect(dictionaryRepresentation: bounds),
          quartzFrame.minX.isFinite, quartzFrame.minY.isFinite,
          quartzFrame.width.isFinite, quartzFrame.height.isFinite,
          quartzFrame.width > 0, quartzFrame.height > 0
    else { return nil }
    return Self.appKitFrame(fromQuartzFrame: quartzFrame)
  }

  func presentContextMenu(event: NSEvent, from view: NSView) {
    cancelPointerGesture()
    let menu = NSMenu(title: "Maaso")
    menu.autoenablesItems = false
    for entry in menuConfiguration.entries {
      let item = NSMenuItem(
        title: entry.label,
        action: #selector(selectConfiguredMenuItem(_:)),
        keyEquivalent: "")
      item.target = self
      item.representedObject = entry.id
      item.isEnabled = entry.isEnabled
      menu.addItem(item)
    }
    if !menuConfiguration.entries.isEmpty {
      menu.addItem(.separator())
    }
    menu.addItem(commandMenuItem(
      title: menuConfiguration.openAppLabel,
      commandID: "openApp"))
    menu.addItem(commandMenuItem(
      title: menuConfiguration.hidePetLabel,
      commandID: "hidePet"))
    menu.addItem(.separator())
    menu.addItem(commandMenuItem(
      title: menuConfiguration.quitLabel,
      commandID: "quit"))
    let location = view.convert(event.locationInWindow, from: nil)
    menu.popUp(positioning: nil, at: location, in: view)
  }

  @objc private func selectConfiguredMenuItem(_ sender: NSMenuItem) {
    guard let itemID = sender.representedObject as? String else { return }
    onMenuSelected(itemID)
  }

  @objc private func selectCommandMenuItem(_ sender: NSMenuItem) {
    guard let commandID = sender.representedObject as? String else { return }
    onCommand(commandID)
  }

  private func commandMenuItem(title: String, commandID: String) -> NSMenuItem {
    let item = NSMenuItem(
      title: title,
      action: #selector(selectCommandMenuItem(_:)),
      keyEquivalent: "")
    item.target = self
    item.representedObject = commandID
    return item
  }

  private func startGazeTracking() {
    guard gazeTimer == nil else { return }
    acceptsMouseMovedEvents = true
    // Global monitors omit this app; the local monitor covers its own windows.
    localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
      [weak self] event in
      self?.updateMousePassthrough()
      return event
    }
    globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
      [weak self] _ in
      self?.updateMousePassthrough()
    }
    let timer = Timer(timeInterval: Self.gazeInterval, repeats: true) {
      [weak self] _ in
      self?.updateGaze()
    }
    gazeTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopGazeTracking() {
    if let monitor = localMouseMoveMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = globalMouseMoveMonitor { NSEvent.removeMonitor(monitor) }
    localMouseMoveMonitor = nil
    globalMouseMoveMonitor = nil
    acceptsMouseMovedEvents = false
    ignoresMouseEvents = true
    gazeTimer?.invalidate()
    gazeTimer = nil
    if lastGaze != nil {
      lastGaze = nil
      onGazeChanged(nil)
    }
  }

  private func updateGaze() {
    guard isVisible else { return }
    updateMousePassthrough()
    let headAnchor = NSPoint(
      x: frame.minX + petContentView.headAnchor.x,
      y: frame.minY + petContentView.headAnchor.y)
    let mouse = NSEvent.mouseLocation
    let gazeScale = presentationConfiguration.visualScale
    let trackedX = ((mouse.x - headAnchor.x) / 220.0 / gazeScale)
      .clamped(to: -1.0 ... 1.0)
    let trackedY = ((mouse.y - headAnchor.y) / 170.0 / gazeScale)
      .clamped(to: -1.0 ... 1.0)
    let avatarRect = petContentView.avatarInteractionRect.offsetBy(
      dx: frame.minX,
      dy: frame.minY)
    let outsideX = max(
      0,
      max(avatarRect.minX - mouse.x, mouse.x - avatarRect.maxX))
    let outsideY = max(
      0,
      max(avatarRect.minY - mouse.y, mouse.y - avatarRect.maxY))
    let outsideDistance = hypot(outsideX, outsideY)
    let fullAttentionDistance = 72.0 * gazeScale
    let releaseDistance = 180.0 * gazeScale
    let attentionWeight = (
      (releaseDistance - outsideDistance)
        / (releaseDistance - fullAttentionDistance)
    ).clamped(to: 0 ... 1)
    let next = CGPoint(
      x: trackedX * attentionWeight,
      y: trackedY * attentionWeight)
    if let previous = lastGaze,
       (next.x == 0 && next.y == 0)
         == (previous.x == 0 && previous.y == 0),
       abs(next.x - previous.x) < Self.gazeDeltaThreshold,
       abs(next.y - previous.y) < Self.gazeDeltaThreshold
    {
      return
    }
    lastGaze = next
    onGazeChanged(next)
  }

  private func updateMousePassthrough() {
    guard isVisible else {
      ignoresMouseEvents = true
      return
    }
    // Keep the original mouse-down receiver until up/cancel, even across frames.
    guard pointerGesture == nil else {
      ignoresMouseEvents = false
      return
    }
    let windowPoint = convertPoint(fromScreen: NSEvent.mouseLocation)
    let point = petContentView.convert(windowPoint, from: nil)
    ignoresMouseEvents = !petContentView.containsVisibleAvatar(at: point)
  }

  @objc private func screenParametersDidChange(_ notification: Notification) {
    cancelPointerGesture()
    restoreSpatialPlacement(panelSize: frame.size)
    updateMousePassthrough()
    updateGaze()
  }

  private func finishSpatialDrop() {
    let monitors = Self.monitors()
    guard let monitor = Self.monitor(
      for: Self.visibleAvatarFrame(for: frame), monitors: monitors) else {
      spatialState = nil
      return
    }
    var nextOrigin = Self.clampedOrigin(
      frame.origin,
      panelSize: frame.size,
      visibleFrame: monitor.visibleFrame)
    var attachment: MacOSDesktopPetSpatialAttachment?
    if presentationConfiguration.snapEnabled,
       let candidate = selectedSnapCandidate(
         proposedOrigin: nextOrigin,
         panelSize: frame.size,
         monitor: monitor)
    {
      nextOrigin = Self.clampedOrigin(
        candidate.origin,
        panelSize: frame.size,
        visibleFrame: monitor.visibleFrame)
      attachment = candidate.attachment
    }
    setFrameOrigin(nextOrigin)
    persistSpatialState(attachment: attachment)
  }

  private func selectedSnapCandidate(
    proposedOrigin: NSPoint,
    panelSize: NSSize,
    monitor: MacOSDesktopPetMonitor
  ) -> MacOSDesktopPetSnapCandidate? {
    let candidates = Self.snapCandidates(
      proposedOrigin: proposedOrigin,
      panelSize: panelSize,
      monitor: monitor)
    if let existingAttachment = spatialState?.attachment,
       let retained = candidates.first(where: {
         $0.attachment == existingAttachment
       }),
       retained.distance <= presentationConfiguration.snapReleaseDistance
    {
      return retained
    }
    guard let nearest = candidates.min(by: { $0.distance < $1.distance }),
          nearest.distance <= presentationConfiguration.snapAcquireDistance
    else { return nil }
    return nearest
  }

  private func restoreSpatialPlacement(panelSize: NSSize) {
    guard let state = Self.loadSpatialState() ?? spatialState else {
      let nextOrigin = Self.clampedOrigin(frame.origin, panelSize: panelSize)
      setFrame(
        NSRect(origin: nextOrigin, size: panelSize),
        display: isVisible)
      persistSpatialState(attachment: nil)
      return
    }
    let monitors = Self.monitors()
    guard let monitor = monitors.first(where: { $0.id == state.monitorID })
      ?? Self.mainMonitor(in: monitors)
    else { return }
    var placementMonitor = monitor
    var nextOrigin = Self.origin(
      normalizedX: state.normalizedX,
      normalizedY: state.normalizedY,
      panelSize: panelSize,
      visibleFrame: monitor.visibleFrame)
    var resolvedAttachment: MacOSDesktopPetSpatialAttachment?
    if presentationConfiguration.snapEnabled,
       let attachment = state.attachment
    {
      switch attachment.kind {
      case .workAreaEdge:
        let candidates = Self.snapCandidates(
          proposedOrigin: nextOrigin,
          panelSize: panelSize,
          monitor: monitor)
        if let candidate = candidates.first(where: {
          $0.attachment == attachment
        }) {
          nextOrigin = candidate.origin
          resolvedAttachment = candidate.attachment
        }
      case .windowTop:
        let windowInfo = Self.foreignWindowInfo()
        var targetWindow: MacOSDesktopPetForeignWindow?
        for candidateMonitor in monitors where targetWindow == nil {
          targetWindow = Self.eligibleForeignWindows(
            on: candidateMonitor,
            panelSize: panelSize,
            windowInfo: windowInfo
          ).first(where: { $0.id == attachment.targetID })
        }
        if let targetWindow,
           let targetMonitor = Self.monitor(
             for: targetWindow.frame,
             monitors: monitors)
        {
          let targetFallbackOrigin = Self.origin(
            normalizedX: state.normalizedX,
            normalizedY: state.normalizedY,
            panelSize: panelSize,
            visibleFrame: targetMonitor.visibleFrame)
          let candidates = Self.snapCandidates(
            proposedOrigin: targetFallbackOrigin,
            panelSize: panelSize,
            monitor: targetMonitor,
            foreignWindowInfo: windowInfo)
          if let candidate = candidates.first(where: {
            $0.attachment == attachment
          }) {
            placementMonitor = targetMonitor
            nextOrigin = candidate.origin
            resolvedAttachment = candidate.attachment
          }
        }
      }
    }
    nextOrigin = Self.clampedOrigin(
      nextOrigin,
      panelSize: panelSize,
      visibleFrame: placementMonitor.visibleFrame)
    setFrame(
      NSRect(origin: nextOrigin, size: panelSize),
      display: isVisible)
    persistSpatialState(attachment: resolvedAttachment)
  }

  private func persistSpatialState(
    attachment: MacOSDesktopPetSpatialAttachment?
  ) {
    let monitors = Self.monitors()
    guard let monitor = Self.monitor(
      for: Self.visibleAvatarFrame(for: frame), monitors: monitors) else {
      return
    }
    let normalized = Self.normalizedPosition(
      origin: frame.origin,
      panelSize: frame.size,
      visibleFrame: monitor.visibleFrame)
    let nextState = MacOSDesktopPetSpatialStateV1(
      monitorID: monitor.id,
      normalizedX: normalized.x,
      normalizedY: normalized.y,
      attachment: attachment)
    spatialState = nextState
    UserDefaults.standard.set(
      nextState.dictionary,
      forKey: Self.spatialStateKey)
    UserDefaults.standard.removeObject(forKey: Self.legacyStoredFrameKey)
  }

  private static func loadSpatialState() -> MacOSDesktopPetSpatialStateV1? {
    MacOSDesktopPetSpatialStateV1.parse(
      UserDefaults.standard.dictionary(forKey: spatialStateKey))
  }

  private static func restoredOrInitialFrame(
    panelSize: NSSize,
    spatialState: MacOSDesktopPetSpatialStateV1?
  ) -> NSRect {
    let monitors = monitors()
    if let spatialState,
       let monitor = monitors.first(where: { $0.id == spatialState.monitorID })
        ?? mainMonitor(in: monitors)
    {
      return NSRect(
        origin: origin(
          normalizedX: spatialState.normalizedX,
          normalizedY: spatialState.normalizedY,
          panelSize: panelSize,
          visibleFrame: monitor.visibleFrame),
        size: panelSize)
    }
    if let storedValue = UserDefaults.standard.string(
      forKey: legacyStoredFrameKey)
    {
      let restored = NSRectFromString(storedValue)
      if restored.origin.x.isFinite,
         restored.origin.y.isFinite,
         restored.width.isFinite,
         restored.height.isFinite,
         restored.width > 0,
         restored.height > 0,
         let monitor = monitor(
           for: visibleAvatarFrame(for: NSRect(origin: restored.origin, size: panelSize)),
           monitors: monitors)
      {
        return NSRect(
          origin: clampedOrigin(
            restored.origin,
            panelSize: panelSize,
            visibleFrame: monitor.visibleFrame),
          size: panelSize)
      }
    }
    let visible = mainMonitor(in: monitors)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSRect(
      x: visible.maxX - panelSize.width
        + horizontalVisibleInset(panelSize: panelSize) - 28,
      y: visible.minY + 24,
      width: panelSize.width,
      height: panelSize.height)
  }

  private static func normalizedPosition(
    origin: NSPoint,
    panelSize: NSSize,
    visibleFrame: NSRect
  ) -> CGPoint {
    let clamped = clampedOrigin(
      origin,
      panelSize: panelSize,
      visibleFrame: visibleFrame)
    let horizontalInset = horizontalVisibleInset(panelSize: panelSize)
    let minimumX = visibleFrame.minX - horizontalInset
    let maximumX = max(
      minimumX,
      visibleFrame.maxX - panelSize.width + horizontalInset)
    let travelX = max(0, maximumX - minimumX)
    let avatarHeight = visibleAvatarHeight(panelSize: panelSize)
    let travelY = max(0, visibleFrame.height - avatarHeight)
    let normalizedX = travelX > 0
      ? (clamped.x - minimumX) / travelX
      : 0
    let normalizedY = travelY > 0
      ? (visibleFrame.maxY - avatarHeight - clamped.y) / travelY
      : 0
    return CGPoint(
      x: normalizedX.clamped(to: 0 ... 1),
      y: normalizedY.clamped(to: 0 ... 1))
  }

  private static func origin(
    normalizedX: CGFloat,
    normalizedY: CGFloat,
    panelSize: NSSize,
    visibleFrame: NSRect
  ) -> NSPoint {
    let horizontalInset = horizontalVisibleInset(panelSize: panelSize)
    let minimumX = visibleFrame.minX - horizontalInset
    let maximumX = max(
      minimumX,
      visibleFrame.maxX - panelSize.width + horizontalInset)
    let travelX = max(0, maximumX - minimumX)
    let avatarHeight = visibleAvatarHeight(panelSize: panelSize)
    let travelY = max(0, visibleFrame.height - avatarHeight)
    return clampedOrigin(
      NSPoint(
        x: minimumX + normalizedX * travelX,
        y: visibleFrame.maxY - avatarHeight - normalizedY * travelY),
      panelSize: panelSize,
      visibleFrame: visibleFrame)
  }

  private static func snapCandidates(
    proposedOrigin: NSPoint,
    panelSize: NSSize,
    monitor: MacOSDesktopPetMonitor,
    foreignWindowInfo: [[String: Any]]? = nil
  ) -> [MacOSDesktopPetSnapCandidate] {
    let visible = monitor.visibleFrame
    let horizontalInset = horizontalVisibleInset(panelSize: panelSize)
    let proposed = clampedOrigin(
      proposedOrigin,
      panelSize: panelSize,
      visibleFrame: visible)
    var candidates: [MacOSDesktopPetSnapCandidate] = []
    candidates.reserveCapacity(8)
    var edgeOrigins: [(MacOSDesktopPetSpatialEdge, NSPoint)] = []
    if visible.maxY < monitor.frame.maxY - 0.5 {
      edgeOrigins.append((.top, NSPoint(
        x: proposed.x,
        y: visible.maxY - visibleAvatarHeight(panelSize: panelSize))))
    }
    if visible.minY > monitor.frame.minY + 0.5 {
      edgeOrigins.append((
        .bottom,
        NSPoint(x: proposed.x, y: visible.minY)))
    }
    if visible.minX > monitor.frame.minX + 0.5 {
      edgeOrigins.append((
        .left,
        NSPoint(x: visible.minX - horizontalInset, y: proposed.y)))
    }
    if visible.maxX < monitor.frame.maxX - 0.5 {
      edgeOrigins.append((.right, NSPoint(
        x: visible.maxX - panelSize.width + horizontalInset,
        y: proposed.y)))
    }
    for (edge, rawOrigin) in edgeOrigins {
      let candidateOrigin = clampedOrigin(
        rawOrigin,
        panelSize: panelSize,
        visibleFrame: visible)
      candidates.append(MacOSDesktopPetSnapCandidate(
        attachment: MacOSDesktopPetSpatialAttachment(
          kind: .workAreaEdge,
          targetID: monitor.id,
          edge: edge),
        origin: candidateOrigin,
        distance: hypot(
          candidateOrigin.x - proposed.x,
          candidateOrigin.y - proposed.y)))
    }

    for window in eligibleForeignWindows(
      on: monitor,
      panelSize: panelSize,
      windowInfo: foreignWindowInfo)
    {
      let maximumX = window.frame.maxX - panelSize.width
      let targetX = maximumX >= window.frame.minX
        ? proposed.x.clamped(to: window.frame.minX ... maximumX)
        : window.frame.midX - panelSize.width / 2
      let candidateOrigin = clampedOrigin(
        NSPoint(x: targetX, y: window.frame.maxY),
        panelSize: panelSize,
        visibleFrame: visible)
      guard abs(candidateOrigin.y - window.frame.maxY) < 0.5 else {
        continue
      }
      candidates.append(MacOSDesktopPetSnapCandidate(
        attachment: MacOSDesktopPetSpatialAttachment(
          kind: .windowTop,
          targetID: window.id,
          edge: .top),
        origin: candidateOrigin,
        distance: hypot(
          candidateOrigin.x - proposed.x,
          candidateOrigin.y - proposed.y)))
    }
    return candidates
  }

  private static func eligibleForeignWindows(
    on monitor: MacOSDesktopPetMonitor,
    panelSize: NSSize,
    windowInfo: [[String: Any]]? = nil
  ) -> [MacOSDesktopPetForeignWindow] {
    let resolvedWindowInfo = windowInfo ?? foreignWindowInfo()
    let currentProcessID = Int32(getpid())
    return resolvedWindowInfo.compactMap { info in
      guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
            !CFNumberIsFloatType(ownerPIDNumber),
            ownerPIDNumber.int32Value > 0,
            ownerPIDNumber.int32Value != currentProcessID,
            let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
            !CFNumberIsFloatType(layerNumber),
            layerNumber.intValue == 0,
            let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
            !CFNumberIsFloatType(windowNumber),
            windowNumber.int64Value > 0,
            let ownerName = info[kCGWindowOwnerName as String] as? String,
            !excludedForeignWindowOwners.contains(ownerName),
            !excludedForeignWindowOwnerPrefixes.contains(where: {
              ownerName.lowercased().hasPrefix($0)
            }),
            let alphaNumber = info[kCGWindowAlpha as String] as? NSNumber,
            alphaNumber.doubleValue.isFinite,
            alphaNumber.doubleValue > minimumForeignWindowAlpha,
            let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
            let quartzFrame = CGRect(
              dictionaryRepresentation: boundsDictionary),
            quartzFrame.origin.x.isFinite,
            quartzFrame.origin.y.isFinite,
            quartzFrame.width.isFinite,
            quartzFrame.height.isFinite,
            quartzFrame.width >= max(
              minimumForeignWindowWidth,
              panelSize.width * 0.5),
            quartzFrame.height >= minimumForeignWindowHeight
      else { return nil }
      let appKitFrame = appKitFrame(fromQuartzFrame: quartzFrame)
      guard appKitFrame.intersects(monitor.visibleFrame) else { return nil }
      return MacOSDesktopPetForeignWindow(
        id: "window:\(ownerPIDNumber.int32Value):\(windowNumber.int64Value)",
        frame: appKitFrame)
    }
  }

  private static func foreignWindowInfo() -> [[String: Any]] {
    CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID) as? [[String: Any]] ?? []
  }

  private static func appKitFrame(fromQuartzFrame frame: CGRect) -> NSRect {
    let primaryTop = NSScreen.screens.first(where: {
      abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5
    })?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    return NSRect(
      x: frame.minX,
      y: primaryTop - frame.maxY,
      width: frame.width,
      height: frame.height)
  }

  private static func monitors() -> [MacOSDesktopPetMonitor] {
    NSScreen.screens.compactMap { screen in
      guard let number = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber
      else { return nil }
      let displayID = CGDirectDisplayID(number.uint32Value)
      let monitorID: String
      if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
        let uuid = unmanagedUUID.takeRetainedValue()
        monitorID = (CFUUIDCreateString(nil, uuid) as String).lowercased()
      } else {
        monitorID = "edid:\(CGDisplayVendorNumber(displayID))"
          + ":\(CGDisplayModelNumber(displayID))"
          + ":\(CGDisplaySerialNumber(displayID))"
      }
      return MacOSDesktopPetMonitor(
        screen: screen,
        displayID: displayID,
        id: monitorID,
        frame: screen.frame,
        visibleFrame: screen.visibleFrame)
    }
  }

  private static func mainMonitor(
    in monitors: [MacOSDesktopPetMonitor]
  ) -> MacOSDesktopPetMonitor? {
    let primaryDisplayID = CGMainDisplayID()
    return monitors.first(where: { $0.displayID == primaryDisplayID })
      ?? monitors.first
  }

  private static func monitor(
    for panelFrame: NSRect,
    monitors: [MacOSDesktopPetMonitor]
  ) -> MacOSDesktopPetMonitor? {
    let center = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
    if let containing = monitors.first(where: {
      $0.visibleFrame.contains(center)
    }) {
      return containing
    }
    let intersecting = monitors.max { lhs, rhs in
      intersectionArea(lhs.visibleFrame, panelFrame)
        < intersectionArea(rhs.visibleFrame, panelFrame)
    }
    if let intersecting,
       intersectionArea(intersecting.visibleFrame, panelFrame) > 0
    {
      return intersecting
    }
    return mainMonitor(in: monitors)
  }

  private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    return max(0, intersection.width) * max(0, intersection.height)
  }

  private static func clampedOrigin(
    _ proposed: NSPoint,
    panelSize: NSSize
  ) -> NSPoint {
    let monitors = monitors()
    let proposedFrame = visibleAvatarFrame(for: NSRect(origin: proposed, size: panelSize))
    let center = NSPoint(x: proposedFrame.midX, y: proposedFrame.midY)
    let monitor = monitors.first(where: { $0.visibleFrame.contains(center) })
      ?? monitors.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) })
      ?? mainMonitor(in: monitors)
    guard let monitor else { return proposed }
    return clampedOrigin(
      proposed,
      panelSize: panelSize,
      visibleFrame: monitor.visibleFrame)
  }

  private static func clampedOrigin(
    _ proposed: NSPoint,
    panelSize: NSSize,
    visibleFrame: NSRect
  ) -> NSPoint {
    let horizontalInset = horizontalVisibleInset(panelSize: panelSize)
    let minimumX = visibleFrame.minX - horizontalInset
    let maximumX = max(
      minimumX,
      visibleFrame.maxX - panelSize.width + horizontalInset)
    let avatarHeight = visibleAvatarHeight(panelSize: panelSize)
    return NSPoint(
      x: proposed.x.clamped(
        to: minimumX ... maximumX),
      y: proposed.y.clamped(
        to: visibleFrame.minY
          ... max(visibleFrame.minY, visibleFrame.maxY - avatarHeight)))
  }

  private static func panelSize(visualScale: CGFloat) -> NSSize {
    NSSize(
      width: basePanelSize.width * visualScale,
      height: basePanelSize.height * visualScale)
  }

  private static func horizontalVisibleInset(panelSize: NSSize) -> CGFloat {
    guard basePanelSize.width > 0 else { return 0 }
    let visualScale = panelSize.width / basePanelSize.width
    let avatarWidth = baseAvatarWidth * visualScale
    return max(0, (panelSize.width - avatarWidth) / 2)
  }

  private static func visibleAvatarHeight(panelSize: NSSize) -> CGFloat {
    // Width stays fixed when bubble headroom is temporarily removed for drag.
    let visualScale = panelSize.width / basePanelSize.width
    return baseAvatarHeight * visualScale
  }

  private static func visibleAvatarFrame(for panelFrame: NSRect) -> NSRect {
    let inset = horizontalVisibleInset(panelSize: panelFrame.size)
    return NSRect(
      x: panelFrame.minX + inset,
      y: panelFrame.minY,
      width: panelFrame.width - inset * 2,
      height: visibleAvatarHeight(panelSize: panelFrame.size))
  }

  private var dragThreshold: CGFloat {
    Self.baseDragThreshold * presentationConfiguration.visualScale
  }

  private static func monotonicTimestampMs() -> Int {
    let milliseconds = (ProcessInfo.processInfo.systemUptime * 1_000)
      .rounded(.down)
      .clamped(to: 0 ... maximumTimestampMs)
    return Int(milliseconds)
  }

  private static func windowLevel(alwaysOnTop: Bool) -> NSWindow.Level {
    alwaysOnTop
      ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
      : .normal
  }
}

private final class MacOSDesktopPetContentView: NSView {
  private static let baseAvatarSize = NSSize(width: 160, height: 280)
  private static let baseBubbleHeadroom: CGFloat = 140
  private static let baseHeadAnchorY: CGFloat = 214
  private static let avatarHitInset: CGFloat = 8

  private let avatarLayer = CALayer()
  private let avatarAlphaHitTest = MacOSAvatarAlphaHitTest()
  private let bubbleView = MacOSDesktopPetBubbleView()
  private var visualScale: CGFloat

  private var avatarRect: NSRect {
    let avatarSize = NSSize(
      width: Self.baseAvatarSize.width * visualScale,
      height: Self.baseAvatarSize.height * visualScale)
    return NSRect(
      x: (bounds.width - avatarSize.width) / 2,
      y: 0,
      width: avatarSize.width,
      height: avatarSize.height)
  }

  private var bubbleLayoutBounds: NSRect {
    // Keep incoming replies above the avatar even while native drag crops
    // transparent headroom. The avatar may reach the screen edges without
    // reserving that headroom, so captions must fold back into the work area.
    let layoutBounds = NSRect(origin: bounds.origin, size: NSSize(
      width: bounds.width,
      height: (Self.baseAvatarSize.height + Self.baseBubbleHeadroom) * visualScale))
    guard let window, let screen = window.screen ?? NSScreen.main else {
      return layoutBounds
    }
    let visibleBounds = convert(window.convertFromScreen(screen.visibleFrame), from: nil)
    let availableBounds = layoutBounds.intersection(visibleBounds)
    return availableBounds.isNull || availableBounds.isEmpty ? layoutBounds : availableBounds
  }

  fileprivate var headAnchor: NSPoint {
    let avatar = avatarRect
    return NSPoint(
      x: avatar.midX,
      y: avatar.minY + Self.baseHeadAnchorY * visualScale)
  }

  fileprivate var avatarInteractionRect: NSRect {
    avatarRect.insetBy(dx: -Self.avatarHitInset, dy: -Self.avatarHitInset)
  }

  init(frame frameRect: NSRect, visualScale: CGFloat) {
    self.visualScale = visualScale
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false
    avatarLayer.contentsGravity = .resizeAspect
    avatarLayer.magnificationFilter = .linear
    avatarLayer.minificationFilter = .linear
    avatarLayer.allowsEdgeAntialiasing = true
    avatarLayer.transform = CATransform3DMakeScale(1, -1, 1)
    layer?.addSublayer(avatarLayer)
    addSubview(bubbleView)
    bubbleView.isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    avatarLayer.bounds = NSRect(origin: .zero, size: avatarRect.size)
    avatarLayer.position = NSPoint(x: avatarRect.midX, y: avatarRect.midY)
    updateAvatarContentsScale()
    bubbleView.reflow(in: bubbleLayoutBounds, above: avatarRect.maxY)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateAvatarContentsScale()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateAvatarContentsScale()
  }

  private func updateAvatarContentsScale() {
    avatarLayer.contentsScale = window?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let localPoint = convert(point, from: superview)
    return containsVisibleAvatar(at: localPoint) ? self : nil
  }

  fileprivate func containsVisibleAvatar(at point: NSPoint) -> Bool {
    avatarAlphaHitTest.contains(point, in: avatarRect)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    (window as? MacOSDesktopPetPanel)?.beginDragging(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    (window as? MacOSDesktopPetPanel)?.continueDragging()
  }

  override func mouseUp(with event: NSEvent) {
    (window as? MacOSDesktopPetPanel)?.endDragging(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard containsVisibleAvatar(at: point) else { return }
    (window as? MacOSDesktopPetPanel)?.presentContextMenu(event: event, from: self)
  }

  override func cancelOperation(_ sender: Any?) {
    (window as? MacOSDesktopPetPanel)?.cancelPointerGesture()
  }

  fileprivate func semanticTap(
    at point: NSPoint
  ) -> (
    normalizedX: CGFloat,
    normalizedY: CGFloat,
    region: MacOSDesktopAvatarTapRegion
  )? {
    let avatar = avatarRect
    guard containsVisibleAvatar(at: point),
          avatar.width > 0,
          avatar.height > 0
    else { return nil }

    let normalizedX = ((point.x - avatar.minX) / avatar.width)
      .clamped(to: 0 ... 1)
    let normalizedY = ((avatar.maxY - point.y) / avatar.height)
      .clamped(to: 0 ... 1)
    guard avatar.contains(point) else {
      return (normalizedX, normalizedY, .avatar)
    }
    if normalizedY <= 0.28 {
      return (normalizedX, normalizedY, .head)
    }
    if normalizedY >= 0.82 {
      return (normalizedX, normalizedY, .feet)
    }
    if normalizedX <= 0.32 {
      return (normalizedX, normalizedY, .leftSide)
    }
    if normalizedX >= 0.68 {
      return (normalizedX, normalizedY, .rightSide)
    }
    return (normalizedX, normalizedY, .torso)
  }

  func setAvatarImage(_ image: CGImage) {
    avatarAlphaHitTest.replaceImage(image)
    avatarLayer.contents = image
  }

  func applyVisualScale(_ nextScale: CGFloat) {
    visualScale = nextScale
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  func clearAvatarImage() {
    avatarAlphaHitTest.replaceImage(nil)
    avatarLayer.contents = nil
  }

  func showBubble(text: String) {
    bubbleView.show(text: text, in: bubbleLayoutBounds, above: avatarRect.maxY)
  }

  func clearBubble() {
    bubbleView.isHidden = true
  }
}

private final class MacOSDesktopPetBubbleView: NSView {
  private static let maximumWidth: CGFloat = 272
  private static let minimumWidth: CGFloat = 112
  private static let maximumHeight: CGFloat = 116
  private static let minimumHeight: CGFloat = 46
  private static let tailHeight: CGFloat = 8
  private static let horizontalPadding: CGFloat = 14
  private static let verticalPadding: CGFloat = 10

  private let label = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.22
    layer?.shadowRadius = 10
    layer?.shadowOffset = NSSize(width: 0, height: -2)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = NSColor(calibratedWhite: 0.10, alpha: 1)
    label.maximumNumberOfLines = 4
    label.lineBreakMode = .byTruncatingTail
    label.cell?.wraps = true
    label.cell?.usesSingleLineMode = false
    addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let bodyRect = bounds.insetBy(dx: 0, dy: 0).divided(
      atDistance: Self.tailHeight,
      from: .minYEdge).remainder
    let fill = NSColor(calibratedWhite: 0.98, alpha: 0.96)
    fill.setFill()
    NSBezierPath(roundedRect: bodyRect, xRadius: 16, yRadius: 16).fill()

    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bounds.midX - 8, y: Self.tailHeight + 1))
    tail.line(to: NSPoint(x: bounds.midX, y: 0))
    tail.line(to: NSPoint(x: bounds.midX + 8, y: Self.tailHeight + 1))
    tail.close()
    tail.fill()

    NSColor(calibratedWhite: 0.76, alpha: 0.72).setStroke()
    let border = NSBezierPath(roundedRect: bodyRect.insetBy(dx: 0.5, dy: 0.5),
                              xRadius: 15.5, yRadius: 15.5)
    border.lineWidth = 1
    border.stroke()
  }

  func show(text: String, in containerBounds: NSRect, above avatarTop: CGFloat) {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      isHidden = true
      return
    }
    label.stringValue = normalized
    let font = label.font ?? NSFont.systemFont(ofSize: 13)
    let availableBubbleWidth = min(
      Self.maximumWidth,
      max(72, containerBounds.width - 8))
    let availableTextWidth = max(
      44,
      availableBubbleWidth - 2 * Self.horizontalPadding)
    let measured = (normalized as NSString).boundingRect(
      with: NSSize(width: availableTextWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font])
    let width = (ceil(measured.width) + 2 * Self.horizontalPadding)
      .clamped(
        to: min(Self.minimumWidth, availableBubbleWidth)
          ... availableBubbleWidth)
    let bodyHeight = (ceil(measured.height) + 2 * Self.verticalPadding)
      .clamped(
        to: (Self.minimumHeight - Self.tailHeight)
          ... (Self.maximumHeight - Self.tailHeight))
    let height = bodyHeight + Self.tailHeight
    frame.size = NSSize(width: width, height: height)
    reposition(in: containerBounds, above: avatarTop)
    label.frame = NSRect(
      x: Self.horizontalPadding,
      y: Self.tailHeight + Self.verticalPadding,
      width: width - 2 * Self.horizontalPadding,
      height: bodyHeight - 2 * Self.verticalPadding)
    layer?.shadowPath = CGPath(
      roundedRect: NSRect(
        x: 0,
        y: Self.tailHeight,
        width: width,
        height: bodyHeight),
      cornerWidth: 16,
      cornerHeight: 16,
      transform: nil)
    isHidden = false
    needsDisplay = true
  }

  func reposition(in containerBounds: NSRect, above avatarTop: CGFloat) {
    let nextY = min(
      avatarTop + 4,
      max(containerBounds.minY, containerBounds.maxY - frame.height - 4))
    frame.origin = NSPoint(
      x: containerBounds.midX - frame.width / 2,
      y: nextY)
  }

  func reflow(in containerBounds: NSRect, above avatarTop: CGFloat) {
    guard !isHidden else { return }
    show(text: label.stringValue, in: containerBounds, above: avatarTop)
  }
}

private final class MacOSDesktopPetSurfaceRenderer {
  private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  private let context = CIContext(options: [
    .cacheIntermediates: false,
  ])

  func makeImage(frame: MacOSUnitySurfaceFrame) -> CGImage? {
    guard let surface = IOSurfaceLookup(IOSurfaceID(frame.surfaceID)),
          IOSurfaceGetWidth(surface) == frame.width,
          IOSurfaceGetHeight(surface) == frame.height
    else { return nil }
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
    let status = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault,
      surface,
      attributes as CFDictionary,
      &unmanagedPixelBuffer)
    guard status == kCVReturnSuccess,
          let pixelBuffer = unmanagedPixelBuffer?.takeRetainedValue()
    else { return nil }
    let image = CIImage(
      cvPixelBuffer: pixelBuffer,
      options: [.colorSpace: Self.sRGBColorSpace])
    return context.createCGImage(
      image,
      from: image.extent,
      format: .BGRA8,
      colorSpace: Self.sRGBColorSpace)
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}

private final class MacOSAvatarPortalTexture: NSObject, FlutterTexture {
  private let lock = NSLock()
  private var latestPixelBuffer: CVPixelBuffer?

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let pixelBuffer = latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(pixelBuffer)
  }

  func update(frame: MacOSUnitySurfaceFrame) -> Bool {
    guard let surface = IOSurfaceLookup(IOSurfaceID(frame.surfaceID)),
          IOSurfaceGetWidth(surface) == frame.width,
          IOSurfaceGetHeight(surface) == frame.height
    else {
      return false
    }
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
    let status = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault,
      surface,
      attributes as CFDictionary,
      &unmanagedPixelBuffer)
    guard status == kCVReturnSuccess,
          let pixelBuffer = unmanagedPixelBuffer?.takeRetainedValue()
    else { return false }
    Self.attachSRGBMetadata(to: pixelBuffer)
    lock.lock()
    latestPixelBuffer = pixelBuffer
    lock.unlock()
    return true
  }

  private static func attachSRGBMetadata(to pixelBuffer: CVPixelBuffer) {
    if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
      CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferCGColorSpaceKey,
        colorSpace,
        .shouldPropagate)
    }
    CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferColorPrimariesKey,
      kCVImageBufferColorPrimaries_ITU_R_709_2,
      .shouldPropagate)
    CVBufferSetAttachment(
      pixelBuffer,
      kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_sRGB,
      .shouldPropagate)
  }

  func clear() {
    lock.lock()
    latestPixelBuffer = nil
    lock.unlock()
  }
}

private struct MacOSUnitySurfaceFrame {
  let surfaceID: UInt32
  let width: Int
  let height: Int
  let generation: Int
  let frameSequence: Int
}

private final class MacOSUnitySidecarSession {
  private static let protocolVersion = 1
  private static let maximumFrameBytes = 64 * 1024
  private static let maximumSequence = 0x7fff_ffff
  private static let allowedMessageTypes: Set<String> = [
    "hello", "ready", "avatarResult", "surface", "event",
    "error", "shutdown",
  ]

  private let onAvatarReady: () -> Void
  private let onAvatarResult: ([String: Any]) -> Void
  private let onSurface: (MacOSUnitySurfaceFrame) -> Void
  private let onEvent: (String, Int) -> Void
  private let onFailure: (String) -> Void
  private let ioQueue = DispatchQueue(label: "com.futurpals.maaso.avatar-sidecar")
  private let stateLock = NSLock()
  private let token: String
  private let sessionDirectory: URL
  private let socketPath: String
  private var listenerFD: Int32 = -1
  private var connectionFD: Int32 = -1
  private var process: Process?
  private var authenticated = false
  private var stopped = false
  private var incomingSequence = -1
  private var outgoingSequence = 0
  private var pendingFrames: [Data] = []

  init(
    onAvatarReady: @escaping () -> Void,
    onAvatarResult: @escaping ([String: Any]) -> Void,
    onSurface: @escaping (MacOSUnitySurfaceFrame) -> Void,
    onEvent: @escaping (String, Int) -> Void,
    onFailure: @escaping (String) -> Void
  ) throws {
    self.onAvatarReady = onAvatarReady
    self.onAvatarResult = onAvatarResult
    self.onSurface = onSurface
    self.onEvent = onEvent
    self.onFailure = onFailure
    token = try Self.makeToken()
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    sessionDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("m-\(getpid())-\(suffix)", isDirectory: true)
    socketPath = sessionDirectory.appendingPathComponent("s").path
    guard socketPath.utf8.count <= 103 else {
      throw SessionError.socketPathTooLong
    }
  }

  deinit {
    stop()
  }

  func start() throws {
    try FileManager.default.createDirectory(
      at: sessionDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenerFD >= 0 else { throw SessionError.socketCreationFailed(errno) }
    var noSigPipe: Int32 = 1
    setsockopt(
      listenerFD,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size))
    try bindListener()
    guard Darwin.listen(listenerFD, 1) == 0 else {
      throw SessionError.socketListenFailed(errno)
    }
    chmod(socketPath, 0o600)

    let executable = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/MaasoAvatar.app/Contents/MacOS/MaasoAvatar")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw SessionError.sidecarMissing
    }
    let child = Process()
    child.executableURL = executable
    child.arguments = [
      "-screen-fullscreen", "0",
      "-window-mode", "borderless",
      "-force-metal",
      "-nolog",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["MAASO_AVATAR_SESSION_TOKEN"] = token
    environment["MAASO_AVATAR_SOCKET_PATH"] = socketPath
    environment["MAASO_AVATAR_PARENT_PID"] = String(getpid())
    child.environment = environment
    child.standardInput = FileHandle.nullDevice
#if DEBUG
    child.standardOutput = FileHandle.standardError
    child.standardError = FileHandle.standardError
#else
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
#endif
    child.terminationHandler = { [weak self] process in
#if DEBUG
      NSLog(
        "[MacOSUnityAvatarPortal] sidecar exited status=\(process.terminationStatus) "
          + "reason=\(process.terminationReason.rawValue)")
#endif
      self?.fail("sidecarExited")
    }
    try child.run()
    process = child
    ioQueue.async { [weak self] in
      self?.acceptAndRead()
    }
  }

  func sendPortalCommand(
    method: String,
    generation: Int,
    profile: String?,
    targetFps: Int? = nil,
    includeWorld: Bool = false,
    viewportWidth: Int? = nil,
    viewportHeight: Int? = nil
  ) {
    guard ["acquire", "suspend", "resume", "release"].contains(method),
          generation > 0,
          generation <= Self.maximumSequence
    else {
      return
    }
    var payload: [String: Any] = [
      "method": method,
      "generation": generation,
    ]
    if let profile {
      guard ["desktopHigh", "compactHigh", "compactBalanced", "compactLow"].contains(profile)
      else { return }
      payload["profile"] = profile
    }
    if let targetFps {
      guard [24, 30, 60].contains(targetFps) else { return }
      payload["targetFps"] = targetFps
    }
    if includeWorld {
      guard method == "acquire",
            let viewportWidth, (64...3840).contains(viewportWidth),
            let viewportHeight, (64...2160).contains(viewportHeight)
      else { return }
      payload["includeWorld"] = true
      payload["viewportWidth"] = viewportWidth
      payload["viewportHeight"] = viewportHeight
    } else if viewportWidth != nil || viewportHeight != nil {
      return
    }
    enqueue(type: "command", payload: payload)
  }

  func sendAvatarCommand(method: String, json: String) -> Bool {
    guard !method.isEmpty, method.utf8.count <= 64,
          json.utf8.count <= 32 * 1024
    else { return false }
    return enqueue(type: "avatarCommand", payload: [
      "method": method,
      "json": json,
    ], allowPending: method != UnityBackgroundTaskWorkPayload.commandMethod)
  }

  func stop() {
    stateLock.lock()
    if stopped {
      stateLock.unlock()
      return
    }
    stopped = true
    let connection = connectionFD
    let listener = listenerFD
    connectionFD = -1
    listenerFD = -1
    let child = process
    process = nil
    stateLock.unlock()

    if connection >= 0 {
      Darwin.shutdown(connection, SHUT_RDWR)
      Darwin.close(connection)
    }
    if listener >= 0 { Darwin.close(listener) }
    if let child, child.isRunning { child.terminate() }
    unlink(socketPath)
    try? FileManager.default.removeItem(at: sessionDirectory)
  }

  private func bindListener() throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      pathBytes.withUnsafeBytes { source in
        destination.copyBytes(from: source)
      }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listenerFD, $0, length)
      }
    }
    guard status == 0 else { throw SessionError.socketBindFailed(errno) }
  }

  private func acceptAndRead() {
    let accepted = Darwin.accept(listenerFD, nil, nil)
    guard accepted >= 0 else {
      if !isStopped { fail("sidecarAcceptFailed") }
      return
    }
    stateLock.lock()
    if stopped {
      stateLock.unlock()
      Darwin.close(accepted)
      return
    }
    connectionFD = accepted
    var noSigPipe: Int32 = 1
    setsockopt(
      accepted,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size))
    stateLock.unlock()
    readFrames(from: accepted)
  }

  private func readFrames(from descriptor: Int32) {
    var frame = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !isStopped {
      let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      if count <= 0 { break }
      for byte in buffer.prefix(count) {
        if byte == 0x0d {
          fail("sidecarInvalidFrame")
          return
        }
        if byte == 0x0a {
          guard !frame.isEmpty else {
            fail("sidecarInvalidFrame")
            return
          }
          do {
            try handle(frame: frame)
          } catch {
            fail("sidecarProtocolFailure")
            return
          }
          frame.removeAll(keepingCapacity: true)
          continue
        }
        frame.append(byte)
        if frame.count >= Self.maximumFrameBytes {
          fail("sidecarFrameTooLarge")
          return
        }
      }
    }
    if !isStopped { fail("sidecarDisconnected") }
  }

  private func handle(frame data: Data) throws {
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(envelope.keys) == ["version", "session", "sequence", "type", "payload"],
          envelope["version"] as? Int == Self.protocolVersion,
          envelope["session"] as? String == token,
          let sequence = envelope["sequence"] as? Int,
          sequence > incomingSequence,
          sequence >= 0,
          sequence <= Self.maximumSequence,
          let type = envelope["type"] as? String,
          Self.allowedMessageTypes.contains(type),
          let payload = envelope["payload"] as? [String: Any]
    else {
      throw SessionError.invalidEnvelope
    }
    incomingSequence = sequence
    if !authenticated {
      guard type == "hello",
            Set(payload.keys) == ["platform", "processId"],
            payload["platform"] as? String == "macos",
            (payload["processId"] as? Int ?? 0) > 0
      else {
        throw SessionError.invalidHandshake
      }
      stateLock.lock()
      authenticated = true
      stateLock.unlock()
      flushPendingFrames()
      return
    }
    switch type {
    case "ready":
      guard Set(payload.keys) == ["renderer", "commandTransport"],
            payload["renderer"] as? String == "unity",
            payload["commandTransport"] as? String == "sidecar"
      else {
        throw SessionError.invalidAvatarMessage
      }
      DispatchQueue.main.async { [onAvatarReady] in onAvatarReady() }
    case "avatarResult":
      guard Self.isBoundedJSON(payload, depth: 0) else {
        throw SessionError.invalidAvatarMessage
      }
      DispatchQueue.main.async { [onAvatarResult] in onAvatarResult(payload) }
    case "surface":
      let surface = try Self.parseSurface(payload)
      DispatchQueue.main.async { [onSurface] in onSurface(surface) }
    case "event":
      guard Set(payload.keys) == ["name", "generation"],
            let name = payload["name"] as? String,
            !name.isEmpty,
            name.count <= 64,
            let generation = payload["generation"] as? Int,
            generation > 0
      else {
        throw SessionError.invalidEvent
      }
      DispatchQueue.main.async { [onEvent] in onEvent(name, generation) }
    case "error", "shutdown":
      throw SessionError.sidecarRejected
    default:
      throw SessionError.unexpectedMessage
    }
  }

  private static func parseSurface(_ payload: [String: Any]) throws
    -> MacOSUnitySurfaceFrame
  {
    guard Set(payload.keys) == [
      "surfaceId", "width", "height", "generation", "frameSequence", "pixelFormat",
    ],
    payload["pixelFormat"] as? String == "bgra8Unorm_srgb",
    let rawSurfaceID = payload["surfaceId"] as? Int,
    rawSurfaceID > 0, rawSurfaceID <= Int(UInt32.max),
    let width = payload["width"] as? Int,
    width > 0, width <= 3840,
    let height = payload["height"] as? Int,
    height > 0, height <= 2160,
    let generation = payload["generation"] as? Int,
    generation > 0, generation <= maximumSequence,
    let frameSequence = payload["frameSequence"] as? Int,
    frameSequence >= 0, frameSequence <= maximumSequence
    else {
      throw SessionError.invalidSurface
    }
    return MacOSUnitySurfaceFrame(
      surfaceID: UInt32(rawSurfaceID),
      width: width,
      height: height,
      generation: generation,
      frameSequence: frameSequence)
  }

  private static func isBoundedJSON(_ value: Any, depth: Int) -> Bool {
    guard depth <= 6 else { return false }
    if let dictionary = value as? [String: Any] {
      return dictionary.count <= 512 && dictionary.allSatisfy {
        !$0.key.isEmpty && $0.key.utf8.count <= 256 &&
          isBoundedJSON($0.value, depth: depth + 1)
      }
    }
    if let array = value as? [Any] {
      return array.count <= 4096 && array.allSatisfy {
        isBoundedJSON($0, depth: depth + 1)
      }
    }
    if let string = value as? String { return string.utf8.count <= 32 * 1024 }
    if value is NSNull { return true }
    if let number = value as? NSNumber { return number.doubleValue.isFinite }
    return false
  }

  @discardableResult
  private func enqueue(type: String, payload: [String: Any], allowPending: Bool = true) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !stopped, outgoingSequence <= Self.maximumSequence,
          allowPending || (authenticated && connectionFD >= 0) else { return false }
    let envelope: [String: Any] = [
      "version": Self.protocolVersion,
      "session": token,
      "sequence": outgoingSequence,
      "type": type,
      "payload": payload,
    ]
    outgoingSequence += 1
    guard let json = try? JSONSerialization.data(withJSONObject: envelope),
          json.count + 1 <= Self.maximumFrameBytes
    else {
      return false
    }
    var frame = json
    frame.append(0x0a)
    if !authenticated || connectionFD < 0 {
      pendingFrames.append(frame)
      return true
    }
    return sendLocked(frame)
  }

  private func flushPendingFrames() {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard authenticated, connectionFD >= 0 else { return }
    for frame in pendingFrames where !sendLocked(frame) {
      break
    }
    pendingFrames.removeAll()
  }

  private func sendLocked(_ frame: Data) -> Bool {
    var offset = 0
    return frame.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return false }
      while offset < bytes.count {
        let sent = Darwin.send(
          connectionFD,
          base.advanced(by: offset),
          bytes.count - offset,
          0)
        if sent <= 0 { return false }
        offset += sent
      }
      return true
    }
  }

  private var isStopped: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return stopped
  }

  private func fail(_ reason: String) {
    guard !isStopped else { return }
    DispatchQueue.main.async { [onFailure] in onFailure(reason) }
  }

  private static func makeToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    else {
      throw SessionError.randomTokenFailed
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private enum SessionError: Error {
    case randomTokenFailed
    case socketPathTooLong
    case socketCreationFailed(Int32)
    case socketBindFailed(Int32)
    case socketListenFailed(Int32)
    case sidecarMissing
    case invalidEnvelope
    case invalidHandshake
    case invalidSurface
    case invalidEvent
    case invalidAvatarMessage
    case unexpectedMessage
    case sidecarRejected
  }
}
