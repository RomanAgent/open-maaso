import Flutter
import AVFoundation
import CoreLocation
import Darwin
import Speech
import UIKit
import UserNotifications
import WebKit
import webview_flutter_wkwebview

#if canImport(UnityFramework)
import UnityFramework
#endif

private let maasoUnityAvatarReady = Notification.Name("MaasoUnityAvatarReady")
private let maasoUnityAvatarCommandResult = Notification.Name("MaasoUnityAvatarCommandResult")
private let maasoUnityBackdropColor = UIColor(
  red: 1.0,
  green: 251.0 / 255.0,
  blue: 242.0 / 255.0,
  alpha: 1.0
)
private let maasoUnityBackdropViewTag = 0x4D41534F
private let maasoUnityContainerViewTag = 0x4D415350

private func logUnityAvatar(_ message: String) {
#if DEBUG
  NSLog("[UnityAvatar] \(message)")
#endif
}

private func exactPositiveJSONInteger(
  _ raw: Any?,
  maximum: Int64
) -> Int64? {
  guard let number = raw as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite,
        number.doubleValue > 0,
        number.doubleValue <= Double(maximum),
        number.doubleValue.rounded(.towardZero) == number.doubleValue else {
    return nil
  }
  return number.int64Value
}

private func exactNonNegativeJSONInteger(
  _ raw: Any?,
  maximum: Int64 = 9_007_199_254_740_991
) -> Int64? {
  guard let number = raw as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite,
        number.doubleValue >= 0,
        number.doubleValue <= Double(maximum),
        number.doubleValue.rounded(.towardZero) == number.doubleValue else {
    return nil
  }
  return number.int64Value
}

private enum UnityAvatarArbiterPayload {
  private static let maximumPayloadBytes = 256 * 1024
  private static let channels: Set<String> = [
    "mouth", "expression", "gaze", "bodyGesture", "framing",
  ]
  private static let failureCodes: Set<String> = [
    "deadline_expired", "owner_mismatch", "stale_ticket", "invalid_command",
    "mutation_failed", "reset_rejected",
  ]
  private static let commandKeys: Set<String> = [
    "protocolVersion", "requestId", "ticket", "rendererId", "ownerToken",
    "commitToken", "accountGeneration", "rendererGeneration", "channel",
    "fingerprint", "payloadJson", "payloadSha256", "deadlineEpochMs",
    "clearsChannel",
  ]
  private static let resetKeys: Set<String> = [
    "protocolVersion", "requestId", "requirementId", "rendererId",
    "targetOwnerToken", "commitToken", "retiredAccountGeneration",
    "retiredRendererGeneration", "targetAccountGeneration",
    "targetRendererGeneration", "payloadJson", "payloadSha256",
    "deadlineEpochMs",
  ]

  static func isValidArguments(method: String, raw: Any?) -> Bool {
    guard let values = raw as? [String: Any] else { return false }
    let expected = method == "avatarArbiterCommand" ? commandKeys : resetKeys
    guard Set(values.keys) == expected,
          exactNonNegativeJSONInteger(values["protocolVersion"]) == 1,
          identifier(values["requestId"], maximum: 96),
          identifier(values["rendererId"], maximum: 96),
          token(values["commitToken"]),
          sha256(values["payloadSha256"]),
          exactPositiveJSONInteger(
            values["deadlineEpochMs"], maximum: 9_007_199_254_740_991) != nil,
          let payload = values["payloadJson"] as? String,
          !payload.isEmpty,
          payload.utf8.count <= maximumPayloadBytes else {
      return false
    }
    if method == "avatarArbiterCommand" {
      guard exactPositiveJSONInteger(
              values["ticket"], maximum: 9_007_199_254_740_991) != nil,
            token(values["ownerToken"]),
            exactNonNegativeJSONInteger(values["accountGeneration"]) != nil,
            exactNonNegativeJSONInteger(values["rendererGeneration"]) != nil,
            let channel = values["channel"] as? String,
            channels.contains(channel),
            let clears = values["clearsChannel"] as? Bool,
            let fingerprint = values["fingerprint"] as? String else {
        return false
      }
      return clears ? fingerprint.isEmpty : lowerHex(fingerprint, length: 16)
    }
    guard exactPositiveJSONInteger(
            values["requirementId"], maximum: 9_007_199_254_740_991) != nil,
          token(values["targetOwnerToken"]),
          exactNonNegativeJSONInteger(values["retiredAccountGeneration"]) != nil,
          let retiredRenderer = exactNonNegativeJSONInteger(
            values["retiredRendererGeneration"]),
          exactNonNegativeJSONInteger(values["targetAccountGeneration"]) != nil,
          let targetRenderer = exactPositiveJSONInteger(
            values["targetRendererGeneration"], maximum: 9_007_199_254_740_991),
          targetRenderer > retiredRenderer,
          payload == "{\"reset\":true}" else {
      return false
    }
    return true
  }

  static func publicResult(_ raw: [String: Any]) -> [String: Any]? {
    guard let method = raw["method"] as? String,
          method == "avatarArbiterCommand" || method == "avatarArbiterReset" else {
      return nil
    }
    let command = method == "avatarArbiterCommand"
    var expected = command ? commandKeys : resetKeys
    expected.remove("payloadJson")
    expected.formUnion(["method", "ok", "code"])
    guard Set(raw.keys) == expected,
          exactNonNegativeJSONInteger(raw["protocolVersion"]) == 1,
          identifier(raw["requestId"], maximum: 96),
          identifier(raw["rendererId"], maximum: 96),
          token(raw["commitToken"]),
          sha256(raw["payloadSha256"]),
          exactPositiveJSONInteger(
            raw["deadlineEpochMs"], maximum: 9_007_199_254_740_991) != nil,
          let ok = raw["ok"] as? Bool,
          let code = raw["code"] as? String,
          (ok ? code.isEmpty : failureCodes.contains(code)) else {
      return nil
    }
    if command {
      guard exactPositiveJSONInteger(
              raw["ticket"], maximum: 9_007_199_254_740_991) != nil,
            token(raw["ownerToken"]),
            exactNonNegativeJSONInteger(raw["accountGeneration"]) != nil,
            exactNonNegativeJSONInteger(raw["rendererGeneration"]) != nil,
            let channel = raw["channel"] as? String,
            channels.contains(channel),
            let clears = raw["clearsChannel"] as? Bool,
            let fingerprint = raw["fingerprint"] as? String,
            clears ? fingerprint.isEmpty : lowerHex(fingerprint, length: 16) else {
        return nil
      }
    } else {
      guard exactPositiveJSONInteger(
              raw["requirementId"], maximum: 9_007_199_254_740_991) != nil,
            token(raw["targetOwnerToken"]),
            exactNonNegativeJSONInteger(raw["retiredAccountGeneration"]) != nil,
            let retiredRenderer = exactNonNegativeJSONInteger(
              raw["retiredRendererGeneration"]),
            exactNonNegativeJSONInteger(raw["targetAccountGeneration"]) != nil,
            let targetRenderer = exactPositiveJSONInteger(
              raw["targetRendererGeneration"], maximum: 9_007_199_254_740_991),
            targetRenderer > retiredRenderer else {
        return nil
      }
    }
    return raw
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

  private static func sha256(_ raw: Any?) -> Bool {
    guard let value = raw as? String else { return false }
    return lowerHex(value, length: 64)
  }

  private static func lowerHex(_ value: String, length: Int) -> Bool {
    guard value.utf8.count == length else { return false }
    return value.range(
      of: "^[a-f0-9]{\(length)}$", options: .regularExpression) != nil
  }
}

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

private enum UnityAvatarCapabilityPayload {
  private static let states: Set<String> = [
    "supported", "degraded", "unknown", "incompatible",
  ]
  private static let issueSeverities: [String: String] = [
    "missing_humanoid": "blocker", "missing_renderable": "blocker",
    "missing_head": "blocker", "missing_left_eye": "warning",
    "missing_right_eye": "warning", "missing_look_at": "warning",
    "missing_lip_sync": "warning", "missing_blink": "warning",
    "missing_expressions": "warning", "high_vertex_count": "warning",
    "high_material_count": "warning", "high_texture_memory": "warning",
  ]

  static func publicProfile(_ raw: Any?) -> [String: Any]? {
    guard let values = raw as? [String: Any],
          Set(values.keys) == [
            "schemaVersion", "source", "state", "rig", "behavior", "render", "issues",
          ],
          JSONSerialization.isValidJSONObject(values),
          let encoded = try? JSONSerialization.data(withJSONObject: values),
          encoded.count <= 8 * 1024,
          exactNonNegativeJSONInteger(values["schemaVersion"], maximum: 1) == 1,
          values["source"] as? String == "unity",
          let state = values["state"] as? String, states.contains(state),
          let rig = fields(values["rig"], booleans: [
            "humanoid", "head", "leftEye", "rightEye",
          ]),
          let behavior = fields(values["behavior"], booleans: [
            "lookAt", "lipSync", "blink", "expressions",
          ]),
          let render = fields(values["render"], booleans: ["renderable"], integers: [
            "rendererCount": 4096, "skinnedMeshCount": 2048,
            "vertexCount": 10_000_000, "triangleCount": 20_000_000,
            "materialCount": 8192, "textureCount": 8192,
            "maxTextureSize": 16384, "estimatedTextureBytes": 2_147_483_648,
          ]),
          let rawIssues = values["issues"] as? [Any], rawIssues.count <= 16 else {
      return nil
    }
    var issues: [[String: String]] = []
    var seenCodes = Set<String>()
    for value in rawIssues {
      guard let issue = value as? [String: Any],
            Set(issue.keys) == ["code", "severity"],
            let code = issue["code"] as? String,
            let severity = issue["severity"] as? String,
            issueSeverities[code] == severity, seenCodes.insert(code).inserted else {
        return nil
      }
      issues.append(["code": code, "severity": severity])
    }
    // Dart still validates derived state, blockers and the matched model load.
    // Native only forwards the bounded public vocabulary; node names, paths,
    // scanner details and arbitrary model metadata cannot cross this boundary.
    return ["schemaVersion": 1, "source": "unity", "state": state,
            "rig": rig, "behavior": behavior, "render": render, "issues": issues]
  }

  private static func fields(
    _ raw: Any?,
    booleans: Set<String>,
    integers: [String: Int64] = [:]
  ) -> [String: Any]? {
    guard let values = raw as? [String: Any],
          Set(values.keys).isSubset(of: booleans.union(integers.keys)) else {
      return nil
    }
    var result: [String: Any] = [:]
    for (key, value) in values {
      if booleans.contains(key) {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        result[key] = number.boolValue
      } else {
        guard let maximum = integers[key],
              let number = exactNonNegativeJSONInteger(value, maximum: maximum) else {
          return nil
        }
        result[key] = Int(number)
      }
    }
    return result
  }
}

private enum UnityBackgroundTaskWorkPayload {
  private static let commandKeys: Set<String> = [
    "requestId", "sessionId", "phase", "loadRequestId", "sequence",
    "issuedAtEpochMs", "deadlineEpochMs",
  ]
  private static let resultKeys: Set<String> = [
    "method", "requestId", "sessionId", "phase", "loadRequestId",
    "sequence", "ok", "code",
  ]
  private static let stateKeys: Set<String> = [
    "method", "requestId", "sessionId", "loadRequestId", "phase",
    "furnitureId", "sceneId", "sequence", "workSessionId",
  ]
  private static let failureCodes: Set<String> = [
    "invalid_command", "deadline_expired", "model_stale", "stale_sequence",
    "session_ended", "session_mismatch", "authority_owned", "not_ready",
    "presentation_busy", "user_pose_owned", "work_unavailable", "mutation_failed",
  ]

  private static func identifier(_ raw: Any?, maximum: Int = 128) -> Bool {
    guard let text = raw as? String else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && text.count <= maximum
  }

  private static func session(_ raw: Any?) -> Bool {
    guard let text = raw as? String else { return false }
    return text.count == 64 && text.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
  }

  static func isValidArguments(_ raw: Any?) -> Bool {
    guard let values = raw as? [String: Any],
          Set(values.keys) == commandKeys,
          identifier(values["requestId"]),
          identifier(values["loadRequestId"]),
          session(values["sessionId"]),
          let phase = values["phase"] as? String, ["start", "end"].contains(phase),
          exactPositiveJSONInteger(values["sequence"], maximum: 9_007_199_254_740_991) != nil,
          let issued = exactPositiveJSONInteger(
            values["issuedAtEpochMs"], maximum: 9_007_199_254_740_991),
          let deadline = exactPositiveJSONInteger(
            values["deadlineEpochMs"], maximum: 9_007_199_254_740_991),
          deadline > issued, deadline - issued <= 10_000 else { return false }
    return true
  }

  static func publicResult(_ raw: [String: Any]) -> [String: Any]? {
    guard let method = raw["method"] as? String,
          identifier(raw["requestId"]),
          identifier(raw["loadRequestId"]),
          session(raw["sessionId"]),
          let sequence = exactPositiveJSONInteger(
            raw["sequence"], maximum: 9_007_199_254_740_991) else { return nil }
    if method == "setBackgroundTaskWork" {
      guard Set(raw.keys) == resultKeys,
            let phase = raw["phase"] as? String, ["start", "end"].contains(phase),
            let boolean = raw["ok"] as? NSNumber,
            CFGetTypeID(boolean) == CFBooleanGetTypeID(),
            let code = raw["code"] as? String,
            boolean.boolValue ? code.isEmpty : failureCodes.contains(code)
      else { return nil }
      return [
        "method": method, "requestId": raw["requestId"]!,
        "loadRequestId": raw["loadRequestId"]!, "sessionId": raw["sessionId"]!,
        "sequence": Int(sequence), "phase": phase, "ok": boolean.boolValue, "code": code,
      ]
    }
    guard method == "backgroundTaskWorkState", Set(raw.keys) == stateKeys,
          let phase = raw["phase"] as? String,
          ["approaching", "aligning", "seated", "working", "lying", "rising", "standing"].contains(phase),
          let furniture = raw["furnitureId"] as? String,
          ["", "sofa", "chair", "desk", "bed"].contains(furniture),
          phase == "standing" || !furniture.isEmpty,
          identifier(raw["sceneId"], maximum: 128) else { return nil }
    let work = raw["workSessionId"]
    if !(work is NSNull) {
      guard let text = work as? String else { return nil }
      if !text.isEmpty {
        guard session(text), text == raw["sessionId"] as? String,
              furniture == "desk", ["approaching", "aligning", "working"].contains(phase)
        else { return nil }
      }
    }
    return [
      "method": method, "requestId": raw["requestId"]!,
      "loadRequestId": raw["loadRequestId"]!, "sessionId": raw["sessionId"]!,
      "sequence": Int(sequence), "phase": phase, "furnitureId": furniture,
      "sceneId": raw["sceneId"]!, "workSessionId": work ?? NSNull(),
    ]
  }
}

private func publicUnityCommandResultPayload(
  _ notification: Notification
) -> [String: Any]? {
  guard let payload = notification.userInfo?["payload"] as? String,
        let data = payload.data(using: .utf8),
        data.count <= 256 * 1024,
        let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else {
    return nil
  }
  if let method = raw["method"] as? String, UnityAgentSpacePayload.methods.contains(method) {
    return UnityAgentSpacePayload.publicResult(raw)
  }
  if let method = raw["method"] as? String,
     method == "avatarArbiterCommand" || method == "avatarArbiterReset" {
    return UnityAvatarArbiterPayload.publicResult(raw)
  }
  if let method = raw["method"] as? String,
     method == "setBackgroundTaskWork" || method == "backgroundTaskWorkState" {
    return UnityBackgroundTaskWorkPayload.publicResult(raw)
  }
  if raw["method"] as? String == "furnitureState" {
    guard let owner = raw["ownerToken"] as? String, !owner.isEmpty, owner.count <= 256,
          let phase = raw["phase"] as? String,
          ["approaching", "aligning", "seated", "working", "lying", "rising", "standing"].contains(phase),
          let furniture = raw["furnitureId"] as? String, ["", "sofa", "chair", "desk", "bed"].contains(furniture),
          let scene = raw["sceneId"] as? String, !scene.isEmpty, scene.count <= 128,
          let account = exactNonNegativeJSONInteger(raw["accountGeneration"], maximum: 9_007_199_254_740_991),
          let renderer = exactNonNegativeJSONInteger(raw["rendererGeneration"], maximum: 9_007_199_254_740_991),
          let sequence = exactPositiveJSONInteger(raw["sequence"], maximum: 9_007_199_254_740_991)
    else { return nil }
    var result: [String: Any] = ["method": "furnitureState", "ownerToken": owner, "phase": phase,
            "furnitureId": furniture, "sceneId": scene, "accountGeneration": account,
            "rendererGeneration": renderer, "sequence": sequence]
    if let work = raw["workSessionId"], !(work is NSNull) {
      guard let text = work as? String else { return nil }
      if !text.isEmpty {
        guard text.count == 64, text.utf8.allSatisfy({
          ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }), furniture == "desk", ["approaching", "aligning", "working"].contains(phase)
        else { return nil }
        result["workSessionId"] = text
      }
    }
    return result
  }
  guard
        let method = raw["method"] as? String,
        method == "loadAvatar"
          || method == "transitionPresence" || method == "transitionLoginDoorway"
          || method == "setPhoneInteraction",
        let requestId = raw["requestId"] as? String,
        !requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let ok = raw["ok"] as? Bool else {
    return nil
  }
  var result: [String: Any] = [
    "requestId": requestId,
    "method": method,
    "ok": ok,
  ]
  if method == "setPhoneInteraction" {
    guard let interactionId = raw["interactionId"] as? String,
          let phase = raw["phase"] as? String else { return nil }
    result["interactionId"] = interactionId
    result["phase"] = phase
    result["code"] = raw["code"] as? String ?? ""
    return result
  }
  if method == "transitionPresence" || method == "transitionLoginDoorway" {
    guard let transitionId = raw["transitionId"] as? String,
          let phase = raw["phase"] as? String else { return nil }
    result["transitionId"] = transitionId
    result["phase"] = phase
    result["code"] = raw["code"] as? String ?? ""
    return result
  }
  if method == "loadAvatar" {
    if let code = raw["code"] as? String,
       !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result["code"] = code
    }
    if let message = raw["message"] as? String,
       !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result["message"] = message
    }
    if let cacheHit = raw["cacheHit"] as? Bool {
      result["cacheHit"] = cacheHit
    }
    if let assetSha256 = raw["assetSha256"] as? String,
       assetSha256.range(
         of: "^[a-f0-9]{64}$",
         options: .regularExpression
       ) != nil {
      result["assetSha256"] = assetSha256
    }
    if let rawProfile = raw["capabilityProfile"] {
      guard let profile = UnityAvatarCapabilityPayload.publicProfile(rawProfile) else {
        result["ok"] = false
        result["code"] = "invalid_capability_profile"
        result["message"] = "Unity avatar capability profile is invalid."
        return result
      }
      result["capabilityProfile"] = profile
    }
    if let rawVersion = raw["backgroundTaskWorkVersion"] {
      guard let version = exactNonNegativeJSONInteger(
        rawVersion, maximum: 2_147_483_647
      ) else {
        result["ok"] = false
        result["code"] = "invalid_background_task_work_version"
        result["message"] = "Unity avatar work presentation version is invalid."
        return result
      }
      result["backgroundTaskWorkVersion"] = Int(version)
    }
    return result
  }
  return nil

}

private final class MaasoUnityPassthroughView: UIView {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    return false
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeAsrPlugin: NativeAsrPlugin?
  private var systemTtsPlugin: LocalSystemTtsBridge?
  private var appIconPlugin: AppIconPlugin?
  private var sharePlugin: MaasoSharePlugin?
  private var gameSnapshotPlugin: MaasoGameSnapshotPlugin?
  private var streamingAudioSinkPlugin: StreamingAudioSinkPlugin?
  private var locationPlugin: MaasoCityGeocoderBridge?
  private var unityAvatarPlugin: UnityAvatarPlugin?
  private var didRegisterGeneratedPlugins = false
  private var didRegisterMaasoNativePlugins = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeLocalDataFromCloudBackup()
    // Local notification foreground/tap callbacks flow through Flutter's
    // lifecycle delegate. This does not request notification permission or APNs.
    UNUserNotificationCenter.current().delegate = self
    // UIScene creates the implicit engine during scene connection. Register
    // plugins in its ready callback below using that engine's registry.
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func excludeLocalDataFromCloudBackup() {
    // The offline database and saved works live below Application Support.
    // Set the directory policy before Dart opens or creates those files.
    do {
      var directory = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
    } catch {
      NSLog("[OpenMaaso] Could not exclude local app data from system backups")
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    registerGeneratedPluginsIfNeeded(with: engineBridge.pluginRegistry)
    registerMaasoNativePlugins(with: engineBridge.pluginRegistry)
  }

  private func registerGeneratedPluginsIfNeeded(with registry: FlutterPluginRegistry) {
    guard !didRegisterGeneratedPlugins else { return }
    GeneratedPluginRegistrant.register(with: registry)
    didRegisterGeneratedPlugins = true
  }

  private func registerMaasoNativePlugins(with registry: FlutterPluginRegistry) {
    guard !didRegisterMaasoNativePlugins else { return }
    guard let registrar = registry.registrar(forPlugin: "MaasoNativePlugins") else {
      logUnityAvatar("plugin registrar unavailable")
      return
    }
    nativeAsrPlugin = NativeAsrPlugin(
      channel: FlutterMethodChannel(
        name: "maaso/native_asr",
        binaryMessenger: registrar.messenger()
      )
    )
    systemTtsPlugin = LocalSystemTtsBridge(
      channel: FlutterMethodChannel(
        name: "maaso/system_tts",
        binaryMessenger: registrar.messenger()
      )
    )
    appIconPlugin = AppIconPlugin(
      channel: FlutterMethodChannel(
        name: "maaso/app_icon",
        binaryMessenger: registrar.messenger()
      )
    )
    sharePlugin = MaasoSharePlugin(
      channel: FlutterMethodChannel(
        name: "maaso/share",
        binaryMessenger: registrar.messenger()
      ),
      viewControllerProvider: { registrar.viewController }
    )
    streamingAudioSinkPlugin = StreamingAudioSinkPlugin(
      channel: FlutterMethodChannel(
        name: "maaso/streaming_audio_sink",
        binaryMessenger: registrar.messenger()
      )
    )
    locationPlugin = MaasoCityGeocoderBridge(
      channel: FlutterMethodChannel(
        name: "maaso/location", binaryMessenger: registrar.messenger()
      )
    )
    gameSnapshotPlugin = MaasoGameSnapshotPlugin(registrar: registrar)
    registrar.register(
      MaasoFrostedInputFactory(messenger: registrar.messenger()),
      withId: "maaso/frosted_input"
    )
    registrar.register(
      MaasoHomeTextEditorFactory(messenger: registrar.messenger()),
      withId: "maaso/home_text_editor"
    )
    maaso_avatar_portal_register(Unmanaged.passUnretained(registrar).toOpaque())
    unityAvatarPlugin = UnityAvatarPlugin(registrar: registrar)
    didRegisterMaasoNativePlugins = true
    logUnityAvatar("plugin registered")
  }
}

/// Resolves an explicitly requested position into city-level context only.
/// Permission and the one-shot position request belong to geolocator in Dart.
private final class MaasoCityGeocoderBridge {
  private let channel: FlutterMethodChannel
  private let geocoder = CLGeocoder()
  private var pendingRequest: UUID?
  private var pendingResult: FlutterResult?
  private var timeout: DispatchWorkItem?
  private var backgroundObserver: NSObjectProtocol?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.cancel() }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(["status": "unavailable", "code": "cancelled"])
        return
      }
      switch call.method {
      case "reverseGeocode": self.reverseGeocode(call.arguments, result: result)
      case "cancelReverseGeocode":
        self.cancel()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    timeout?.cancel()
    geocoder.cancelGeocode()
    pendingResult?(["status": "unavailable", "code": "cancelled"])
  }

  private func reverseGeocode(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let values = arguments as? [String: Any],
          Set(values.keys) == ["latitude", "longitude"],
          let latitude = coordinate(values["latitude"], limit: 90),
          let longitude = coordinate(values["longitude"], limit: 180) else {
      result(["status": "unavailable", "code": "invalid_coordinates"])
      return
    }
    guard UIApplication.shared.applicationState == .active else {
      result(["status": "unavailable", "code": "cancelled"])
      return
    }
    guard pendingRequest == nil else {
      result(["status": "unavailable", "code": "busy"])
      return
    }
    let request = UUID()
    pendingRequest = request
    pendingResult = result
    let deadline = DispatchWorkItem { [weak self] in
      self?.finish(request, payload: ["status": "unavailable", "code": "timeout"])
      self?.geocoder.cancelGeocode()
    }
    timeout = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
    geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)) {
      [weak self] placemarks, error in
      DispatchQueue.main.async {
        guard let self, self.pendingRequest == request else { return }
        guard UIApplication.shared.applicationState == .active else {
          self.finish(request, payload: ["status": "unavailable", "code": "cancelled"])
          return
        }
        guard error == nil, let place = placemarks?.first else {
          self.finish(request, payload: ["status": "unavailable", "code": "geocoder_failed"])
          return
        }
        guard let city = self.cityText(place.locality) else {
          self.finish(request, payload: ["status": "unavailable", "code": "city_unavailable"])
          return
        }
        self.finish(request, payload: ["status": "available", "city": city,
          "region": self.cityText(place.administrativeArea) ?? "",
          "country": self.cityText(place.country) ?? "",
          "countryCode": self.countryCode(place.isoCountryCode) ?? ""])
      }
    }
  }

  private func coordinate(_ raw: Any?, limit: Double) -> Double? {
    guard let value = raw as? NSNumber,
          CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite, abs(value.doubleValue) <= limit else { return nil }
    return value.doubleValue
  }

  private func cityText(_ raw: String?) -> String? {
    guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty, text.count <= 120,
          text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
    return text
  }

  private func countryCode(_ raw: String?) -> String? {
    guard let code = raw, code.utf8.count == 2,
          code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else {
      return nil
    }
    return code
  }

  private func finish(_ request: UUID, payload: [String: Any]) {
    guard pendingRequest == request else { return }
    let result = pendingResult
    pendingRequest = nil
    pendingResult = nil
    timeout?.cancel()
    timeout = nil
    result?(payload)
  }

  private func cancel() {
    if let request = pendingRequest {
      finish(request, payload: ["status": "unavailable", "code": "cancelled"])
    }
    geocoder.cancelGeocode()
  }
}

/// Captures only the WKWebView already on screen after an explicit game open.
/// This bridge never creates a player, navigates, or executes game JavaScript.
private final class MaasoGameSnapshotPlugin {
  private let channel: FlutterMethodChannel
  private var activeCapture: UUID?

  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "maaso/game_snapshot", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "captureOpenedPlayer" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self, self.activeCapture == nil,
            UIApplication.shared.applicationState == .active,
            let arguments = call.arguments as? [String: Any],
            Set(arguments.keys) == ["webViewIdentifier"],
            let identifier = exactNonNegativeJSONInteger(arguments["webViewIdentifier"]),
            let webView = FWFWebViewFlutterWKWebViewExternalAPI.webView(
              forIdentifier: identifier, withPluginRegistrar: registrar),
            let window = webView.window, !window.isHidden,
            !webView.isHidden, webView.alpha > 0,
            webView.bounds.width > 0, webView.bounds.height > 0,
            webView.convert(webView.bounds, to: window).intersects(window.bounds) else {
        result(nil)
        return
      }
      let captureID = UUID()
      self.activeCapture = captureID
      let configuration = WKSnapshotConfiguration()
      configuration.rect = webView.bounds
      let factor = min(1, 640 / max(webView.bounds.width, webView.bounds.height))
      configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width * factor))
      configuration.afterScreenUpdates = true
      var completed = false
      let finish: (Data?) -> Void = { data in
        guard !completed else { return }
        completed = true
        result(data.map { FlutterStandardTypedData(bytes: $0) })
      }
      // A logical deadline does not cancel WKWebView's physical snapshot.
      // Keep ownership until that exact callback drains; otherwise polling can
      // accumulate overlapping native work behind timed-out Dart requests.
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finish(nil) }
      webView.takeSnapshot(with: configuration) { [weak self, weak webView, weak window] image, _ in
        guard let self, self.activeCapture == captureID else { finish(nil); return }
        defer {
          if self.activeCapture == captureID { self.activeCapture = nil }
        }
        guard !completed,
              UIApplication.shared.applicationState == .active,
              let webView, let window, webView.window === window,
              !webView.isHidden, webView.alpha > 0,
              webView.convert(webView.bounds, to: window).intersects(window.bounds),
              let image, image.size.width > 0, image.size.height > 0 else {
          finish(nil)
          return
        }
        let scale = min(1, 640 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
          UIColor.black.setFill()
          UIRectFill(CGRect(origin: .zero, size: size))
          image.draw(in: CGRect(origin: .zero, size: size))
        }
        let data = thumbnail.jpegData(compressionQuality: 0.78)
        finish(data.flatMap { $0.count <= 256 * 1024 ? $0 : nil })
      }
    }
  }
}

private final class MaasoSharePlugin {
  private let viewControllerProvider: () -> UIViewController?

  init(
    channel: FlutterMethodChannel,
    viewControllerProvider: @escaping () -> UIViewController?
  ) {
    self.viewControllerProvider = viewControllerProvider
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "share" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.share(arguments: call.arguments, result: result)
    }
  }

  private func share(arguments: Any?, result: @escaping FlutterResult) {
    guard let values = arguments as? [String: Any],
          let text = values["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      result(FlutterError(
        code: "invalid_share",
        message: "Share text is required.",
        details: nil
      ))
      return
    }
    var items: [Any] = [text]
    if let path = values["filePath"] as? String,
       FileManager.default.fileExists(atPath: path) {
      items.append(URL(fileURLWithPath: path))
    }
    guard let presenter = topViewController(from: viewControllerProvider())
      ?? FlutterHostViewResolver.currentViewController() else {
      result(false)
      return
    }
    let activity = UIActivityViewController(
      activityItems: items,
      applicationActivities: nil
    )
    if let popover = activity.popoverPresentationController {
      let origin = values["origin"] as? [String: NSNumber]
      if let origin {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(
          x: origin["left"]?.doubleValue ?? presenter.view.bounds.midX,
          y: origin["top"]?.doubleValue ?? presenter.view.bounds.midY,
          width: max(origin["width"]?.doubleValue ?? 1, 1),
          height: max(origin["height"]?.doubleValue ?? 1, 1)
        )
      } else {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(
          x: presenter.view.bounds.midX,
          y: presenter.view.bounds.midY,
          width: 1,
          height: 1
        )
      }
    }
    presenter.present(activity, animated: true) {
      result(true)
    }
  }

  private func topViewController(
    from root: UIViewController?
  ) -> UIViewController? {
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    if let navigation = root as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tabs = root as? UITabBarController {
      return topViewController(from: tabs.selectedViewController)
    }
    return root
  }
}

private final class AppIconPlugin {
  init(channel: FlutterMethodChannel) {
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setThemeIcon" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let arguments = call.arguments as? [String: Any]
      self?.setThemeIcon(dark: arguments?["dark"] as? Bool ?? true, result: result)
    }
  }

  private func setThemeIcon(dark: Bool, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let application = UIApplication.shared
      guard application.supportsAlternateIcons else {
        result(false)
        return
      }
      let iconName = dark ? nil : "AppIconLight"
      guard application.alternateIconName != iconName else {
        result(true)
        return
      }
      application.setAlternateIconName(iconName) { error in
        if let error {
          result(FlutterError(
            code: "app_icon_update_failed",
            message: error.localizedDescription,
            details: nil
          ))
        } else {
          result(true)
        }
      }
    }
  }
}

protocol UnityAvatarCommandSink: AnyObject {
  var onSceneReady: (() -> Void)? { get set }
  var onPresentationState: ((String, Bool) -> Void)? { get set }
  func requestPresentation(_ presentationId: String)
  func attachToFlutterHost()
  func attach(to view: UIView)
  func detach()
  func markUnitySceneReady()
  func send(method: String, arguments: Any?)
  func sendTicketed(method: String, arguments: Any?) -> Bool
}

final class PlaceholderUnityAvatarCommandSink: UnityAvatarCommandSink {
  var onSceneReady: (() -> Void)?
  var onPresentationState: ((String, Bool) -> Void)?
  func requestPresentation(_ presentationId: String) {
    onPresentationState?(presentationId, false)
  }
  func attachToFlutterHost() {}
  func attach(to view: UIView) {}
  func detach() {}
  func markUnitySceneReady() {
    onSceneReady?()
  }
  func send(method: String, arguments: Any?) {}
  func sendTicketed(method: String, arguments: Any?) -> Bool { false }
}

private enum FlutterHostViewResolver {
  static func currentViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    return topViewController(from: window?.rootViewController)
  }

  private static func topViewController(from root: UIViewController?) -> UIViewController? {
    if let navigation = root as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = root as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    return root
  }
}

private enum UnityAvatarCommandSinkFactory {
  static func make(hostViewController: UIViewController? = nil) -> UnityAvatarCommandSink {
    let runtimeSink = RuntimeUnityAvatarCommandSink(
      hostViewController: hostViewController ?? FlutterHostViewResolver.currentViewController()
    )
    return runtimeSink.isAvailable
      ? runtimeSink
      : PlaceholderUnityAvatarCommandSink()
  }
}

private typealias UnitySendMessageFunction = @convention(c) (
  UnsafePointer<CChar>,
  UnsafePointer<CChar>,
  UnsafePointer<CChar>
) -> Void

enum UnityAvatarRuntimeBridge {
  static var commandSink: RuntimeUnityAvatarCommandSink?
  static var sceneReadyObserver: NSObjectProtocol?
  private static var lifecycle = UnityAvatarLifecycleState()
  static var hostPhase: UnityAvatarScenePhase? { lifecycle.hostPhase }

  static func handleSceneLifecycle(_ event: UnityAvatarLifecycleEvent) {
    // Recording a scene event must never create or start the Unity player.
    let events = lifecycle.receive(event)
    commandSink?.applySceneLifecycle(events)
    commandSink?.synchronizeSceneLifecycle()
    if event == .didBecomeActive {
      commandSink?.resumeRequestedAttachment()
    } else {
      commandSink?.invalidatePresentation()
    }
  }

  static func synchronizePlayer(isReady: Bool, fallbackHostPhase: UnityAvatarScenePhase) {
    let events = lifecycle.synchronizePlayer(
      isReady: isReady,
      fallbackHostPhase: fallbackHostPhase
    )
    commandSink?.applySceneLifecycle(events)
  }

  static func register(commandSink: RuntimeUnityAvatarCommandSink) {
    self.commandSink = commandSink
    guard sceneReadyObserver == nil else { return }
    sceneReadyObserver = NotificationCenter.default.addObserver(
      forName: maasoUnityAvatarReady,
      object: nil,
      queue: .main
    ) { _ in
      self.commandSink?.markUnitySceneReady()
    }
  }
}

final class RuntimeUnityAvatarCommandSink: UnityAvatarCommandSink {
  private static let gameObjectName = "Main Camera"
  private static let functionName = "OnFlutterCommand"
  private let sendMessage: UnitySendMessageFunction?
  private weak var hostViewController: UIViewController?
  private var attachRetryCount = 0
  private var pendingCommands: [String] = []
  private var isUnitySceneReady = false
  private var attachment = UnityAvatarAttachmentState()
  var onPresentationState: ((String, Bool) -> Void)?

  func requestPresentation(_ presentationId: String) {
    attachment.request(presentationId: presentationId)
  }

  func invalidatePresentation() {
    guard let presentationId = attachment.presentationId else { return }
    onPresentationState?(presentationId, false)
  }
#if canImport(UnityFramework)
  private let unityFramework: UnityFramework?
  private weak var unityView: UIView?
  private weak var unityContainerView: UIView?
#endif

  var onSceneReady: (() -> Void)? {
    didSet {
      guard isUnitySceneReady else { return }
      DispatchQueue.main.async { [weak self] in
        self?.onSceneReady?()
      }
    }
  }

  var isAvailable: Bool {
#if canImport(UnityFramework)
    return unityFramework != nil || sendMessage != nil
#else
    return sendMessage != nil
#endif
  }

  fileprivate init(
    hostViewController: UIViewController? = nil,
    sendMessage: UnitySendMessageFunction? = RuntimeUnityAvatarCommandSink.resolveUnitySendMessage()
  ) {
    self.hostViewController = hostViewController
    self.sendMessage = sendMessage
#if canImport(UnityFramework)
    unityFramework = UnityFramework.getInstance()
    logUnityAvatar(
      "sink init unityFramework=\(unityFramework != nil) sendMessage=\(sendMessage != nil)"
    )
#else
    logUnityAvatar("sink init unityFramework=false sendMessage=\(sendMessage != nil)")
#endif
    UnityAvatarRuntimeBridge.register(commandSink: self)
  }

  func attachToFlutterHost() {
    attachment.request()
    if hostViewController == nil {
      hostViewController = FlutterHostViewResolver.currentViewController()
    }
    guard let flutterView = hostViewController?.view else {
      invalidatePresentation()
      logUnityAvatar("attach skipped: no Flutter host view")
      return
    }
    logUnityAvatar(
      "attach requested flutterView=\(type(of: flutterView)) hasSuperview=\(flutterView.superview != nil)"
    )
    attach(to: flutterView)
  }

  func attach(to view: UIView) {
    attachment.request()
#if canImport(UnityFramework)
    guard UIApplication.shared.applicationState == .active,
          UnityAvatarRuntimeBridge.hostPhase != .inactive,
          UnityAvatarRuntimeBridge.hostPhase != .background else {
      invalidatePresentation()
      logUnityAvatar("attach deferred: Flutter scene is not active")
      return
    }
    configureFlutterHostForUnityUnderlay()
    guard let unityRootView = resolveUnityView() else {
      invalidatePresentation()
      logUnityAvatar("attach skipped: Unity root view unavailable")
      return
    }
    configureUnityRootView(unityRootView)
    if attachUnityRootViewAsFlutterUnderlay(unityRootView) {
      return
    }
#else
    invalidatePresentation()
    logUnityAvatar("attach skipped: UnityFramework not importable")
#endif
  }

  func detach() {
    invalidatePresentation()
    attachment.detach()
    attachRetryCount = 0
#if canImport(UnityFramework)
    unityView?.removeFromSuperview()
    unityContainerView?.removeFromSuperview()
    unityView = nil
    unityContainerView = nil
#endif
    // The plugin owns readiness for the retained engine, independently of
    // whether a Flutter page currently owns its underlay.
  }

  func resumeRequestedAttachment() {
    guard let token = attachment.requestedGeneration else { return }
    // Flutter can request prepareView before UIKit finishes scene activation.
    // Replay after that callback stack, even when Unity retained isReady=true.
    DispatchQueue.main.async { [weak self] in
      guard let self,
            self.attachment.isCurrent(token),
            UnityAvatarRuntimeBridge.hostPhase == .active else { return }
      self.attachRetryCount = 0
      self.attachToFlutterHost()
    }
  }

  func send(method: String, arguments: Any?) {
    guard let payload = arguments as? String else {
      return
    }
    guard isUnitySceneReady else {
      pendingCommands.append(payload)
      logUnityAvatar("queue command \(method) until scene ready pending=\(pendingCommands.count)")
      return
    }
    sendPayload(payload)
  }

  func sendTicketed(method: String, arguments: Any?) -> Bool {
    guard isUnitySceneReady,
          sendMessage != nil,
          let payload = arguments as? String else {
      return false
    }
    sendPayload(payload)
    return true
  }

  func markUnitySceneReady() {
    // The native ready notification is dispatched to the main queue after the
    // Unity startup stack returns, including debug builds' deferred startup.
    synchronizeSceneLifecycle()
    guard !isUnitySceneReady else { return }
    isUnitySceneReady = true
    logUnityAvatar("scene ready pending=\(pendingCommands.count)")
    flushPendingCommands()
    onSceneReady?()
  }

  private func flushPendingCommands() {
    let commands = pendingCommands
    pendingCommands.removeAll()
    for command in commands {
      sendPayload(command)
    }
  }

  private func sendPayload(_ payload: String) {
    guard let sendMessage else {
      return
    }
    Self.gameObjectName.withCString { gameObject in
      Self.functionName.withCString { function in
        payload.withCString { message in
          sendMessage(gameObject, function, message)
        }
      }
    }
  }

  private static func resolveUnitySendMessage() -> UnitySendMessageFunction? {
    let handle = dlopen(nil, RTLD_LAZY)
    return "UnitySendMessage".withCString { symbolName in
      guard let symbol = dlsym(handle, symbolName) else {
        return nil
      }
      return unsafeBitCast(symbol, to: UnitySendMessageFunction.self)
    }
  }

#if canImport(UnityFramework)
  func synchronizeSceneLifecycle() {
    guard let appController = unityFramework?.appController() else { return }
    // A controller exists before graphics initialization finishes. Active
    // callbacks can start Unity at that point, so do not replay them yet.
    guard appController.engineLoadState.rawValue >= kUnityEngineLoadStateCoreInitialized.rawValue else {
      return
    }
    let hostPhase: UnityAvatarScenePhase
    switch UIApplication.shared.applicationState {
    case .active:
      hostPhase = .active
    case .inactive:
      hostPhase = .inactive
    case .background:
      hostPhase = .background
    @unknown default:
      hostPhase = .inactive
    }
    UnityAvatarRuntimeBridge.synchronizePlayer(
      isReady: appController.engineLoadState.rawValue >= kUnityEngineLoadStateAppReady.rawValue,
      fallbackHostPhase: hostPhase
    )
  }

  func applySceneLifecycle(_ events: [UnityAvatarLifecycleEvent]) {
    guard let appController = unityFramework?.appController() else { return }
    let application = UIApplication.shared
    for event in events {
      logUnityAvatar("scene lifecycle \(event.rawValue)")
      switch event {
      case .willResignActive:
        appController.applicationWillResignActive(application)
      case .didEnterBackground:
        appController.applicationDidEnterBackground(application)
      case .willEnterForeground:
        appController.applicationWillEnterForeground(application)
      case .didBecomeActive:
        appController.applicationDidBecomeActive(application)
      }
    }
  }
#else
  func synchronizeSceneLifecycle() {}
  func applySceneLifecycle(_ events: [UnityAvatarLifecycleEvent]) {}
#endif

#if canImport(UnityFramework)
  private func configureUnityRootView(_ unityRootView: UIView) {
    unityRootView.isHidden = false
    unityRootView.backgroundColor = UIColor.clear
    unityRootView.isOpaque = false
    unityRootView.isUserInteractionEnabled = false
    unityRootView.clipsToBounds = true
    unityRootView.layer.zPosition = 0
    disableInteractionRecursively(unityRootView)
  }

  private func attachUnityRootViewAsFlutterUnderlay(_ unityRootView: UIView) -> Bool {
    guard let flutterView = hostViewController?.view else {
      invalidatePresentation()
      logUnityAvatar("underlay attach failed: no Flutter view")
      return false
    }
    configureFlutterHostForUnityUnderlay()

    guard let superview = flutterView.superview else {
      invalidatePresentation()
      guard attachRetryCount < 8 else {
        logUnityAvatar("underlay attach failed: no superview after retries")
        return false
      }
      attachRetryCount += 1
      logUnityAvatar("underlay attach waiting for superview retry=\(attachRetryCount)")
      let token = attachment.requestedGeneration
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self, let token, self.attachment.isCurrent(token) else { return }
        self.attachToFlutterHost()
      }
      return true
    }

    // prepareView can arrive repeatedly from Flutter's resume and layout paths.
    // Keep the live rendering layer in its existing hierarchy on those calls.
    if let container = unityContainerView,
       container.superview === superview,
       unityRootView.superview === container {
      if container.frame != superview.bounds {
        container.frame = superview.bounds
      }
      if unityRootView.frame != container.bounds {
        unityRootView.frame = container.bounds
      }
      attachRetryCount = 0
      configureUnityWindowForFlutterUnderlay(restoreFlutterWindow: flutterView.window ?? superview.window)
      publishAttachedPresentation(unityRootView, flutterView: flutterView, container: container)
      return true
    }

    let flutterWindow = flutterView.window ?? superview.window
    installUnityBackdrop(in: superview, below: flutterView)
    let container = installUnityContainer(in: superview, below: flutterView)
    unityRootView.removeFromSuperview()
    unityRootView.frame = container.bounds
    unityRootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(unityRootView)
    container.layer.zPosition = -1
    flutterView.layer.zPosition = 0
    disableInteractionRecursively(unityRootView)
    unityView = unityRootView
    unityContainerView = container
    attachRetryCount = 0
    configureUnityWindowForFlutterUnderlay(restoreFlutterWindow: flutterWindow)
    publishAttachedPresentation(unityRootView, flutterView: flutterView, container: container)
    logUnityAvatar(
      "underlay attached unityFrame=\(unityRootView.frame) containerFrame=\(container.frame) hostFrame=\(flutterView.frame)"
    )
    return true
  }

  private func publishAttachedPresentation(
    _ unityRootView: UIView,
    flutterView: UIView,
    container: UIView
  ) {
    guard let token = attachment.requestedGeneration,
          let presentationId = attachment.presentationId else { return }
    // A scene-ready engine may have no window yet. Confirm the actual visible
    // underlay, not just successful command dispatch or a retained root view.
    let attached = attachment.isCurrent(token)
      && UIApplication.shared.applicationState == .active
      && UnityAvatarRuntimeBridge.hostPhase == .active
      && flutterView.window != nil
      && flutterView.window === unityRootView.window
      && unityRootView.superview === container
      && container.superview === flutterView.superview
      && !container.isHidden && !unityRootView.isHidden
      && flutterView.window?.isHidden == false
      && unityRootView.bounds.width > 0 && unityRootView.bounds.height > 0
    onPresentationState?(presentationId, attached)
  }

  private func configureFlutterHostForUnityUnderlay() {
    guard let flutterView = hostViewController?.view else { return }
    if let flutterViewController = hostViewController as? FlutterViewController {
      flutterViewController.isViewOpaque = false
    }
    flutterView.isOpaque = false
    flutterView.backgroundColor = UIColor.clear
    hostViewController?.view.isOpaque = false
    hostViewController?.view.backgroundColor = UIColor.clear
  }

  private func installUnityBackdrop(in superview: UIView, below flutterView: UIView) {
    superview.backgroundColor = maasoUnityBackdropColor
    superview.window?.backgroundColor = maasoUnityBackdropColor

    let backdropView = superview.subviews.first {
      $0.tag == maasoUnityBackdropViewTag
    } ?? UIView(frame: superview.bounds)
    backdropView.tag = maasoUnityBackdropViewTag
    backdropView.backgroundColor = maasoUnityBackdropColor
    backdropView.isUserInteractionEnabled = false
    backdropView.layer.zPosition = -2
    backdropView.frame = superview.bounds
    backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    backdropView.removeFromSuperview()
    superview.insertSubview(backdropView, belowSubview: flutterView)
  }

  private func installUnityContainer(in superview: UIView, below flutterView: UIView) -> UIView {
    let container = superview.subviews.first {
      $0.tag == maasoUnityContainerViewTag
    } as? MaasoUnityPassthroughView ?? MaasoUnityPassthroughView(frame: superview.bounds)
    container.tag = maasoUnityContainerViewTag
    container.backgroundColor = UIColor.clear
    container.isOpaque = false
    container.isUserInteractionEnabled = false
    container.clipsToBounds = true
    container.frame = superview.bounds
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.subviews.forEach { $0.removeFromSuperview() }
    container.removeFromSuperview()
    superview.insertSubview(container, belowSubview: flutterView)
    return container
  }

  private func disableInteractionRecursively(_ view: UIView) {
    view.isUserInteractionEnabled = false
    view.subviews.forEach { disableInteractionRecursively($0) }
  }

  private func configureUnityWindowForFlutterUnderlay(restoreFlutterWindow flutterWindow: UIWindow?) {
    guard let unityWindow = unityFramework?.appController()?.window else {
      return
    }
    guard unityWindow !== flutterWindow else {
      flutterWindow?.makeKeyAndVisible()
      return
    }
    unityWindow.isUserInteractionEnabled = false
    unityWindow.isHidden = true
    flutterWindow?.isHidden = false
    flutterWindow?.makeKeyAndVisible()
  }

  private func resolveUnityView() -> UIView? {
    if let unityView {
      synchronizeSceneLifecycle()
      return unityView
    }
    guard let unityFramework else {
      logUnityAvatar("resolveUnityView failed: UnityFramework instance nil")
      return nil
    }
    if unityFramework.appController() == nil {
      logUnityAvatar("starting Unity runEmbedded")
      unityFramework.setDataBundleId("com.unity3d.framework")
      unityFramework.runEmbedded(
        withArgc: CommandLine.argc,
        argv: CommandLine.unsafeArgv,
        appLaunchOpts: nil
      )
    }
    synchronizeSceneLifecycle()
    let rootView = unityFramework.appController()?.rootView
    unityView = rootView
    logUnityAvatar("resolved Unity root view=\(rootView != nil)")
    return rootView
  }
#endif
}

private enum UnityAvatarCommandPayload {
  static func encode(method: String, arguments: Any?) -> String {
    let json = jsonString(from: normalize(arguments))
    return jsonString(from: [
      "method": method,
      "json": json
    ])
  }

  private static func normalize(_ value: Any?) -> Any {
    guard let value else { return [String: Any]() }
    if let dict = value as? [String: Any] {
      return dict.mapValues { normalize($0) }
    }
    if let array = value as? [Any] {
      return array.map { normalize($0) }
    }
    if let data = value as? FlutterStandardTypedData {
      return ["byteLength": data.data.count]
    }
    if value is String || value is NSNumber || value is NSNull {
      return value
    }
    return String(describing: value)
  }

  private static func jsonString(from object: Any) -> String {
    let serializable = JSONSerialization.isValidJSONObject(object)
      ? object
      : ["value": object]
    guard let data = try? JSONSerialization.data(withJSONObject: serializable),
          let text = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return text
  }
}

final class UnityAvatarPlugin: NSObject {
  private static let channelName = "maaso/unity_avatar"
  private let channel: FlutterMethodChannel
  private let commandSink: UnityAvatarCommandSink
  private var commandResultObserver: NSObjectProtocol?

  init(
    registrar: FlutterPluginRegistrar,
    commandSink: UnityAvatarCommandSink? = nil
  ) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: registrar.messenger()
    )
    let resolvedCommandSink = commandSink ??
      UnityAvatarCommandSinkFactory.make(hostViewController: registrar.viewController)
    self.commandSink = resolvedCommandSink
    super.init()
    resolvedCommandSink.onSceneReady = { [weak channel] in
      channel?.invokeMethod("ready", arguments: nil)
    }
    resolvedCommandSink.onPresentationState = { [weak channel] presentationId, attached in
      channel?.invokeMethod("presentationState", arguments: [
        "presentationId": presentationId,
        "attached": attached
      ])
    }
    commandResultObserver = NotificationCenter.default.addObserver(
      forName: maasoUnityAvatarCommandResult,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let payload = publicUnityCommandResultPayload(notification) else {
        logUnityAvatar("dropped invalid command result notification")
        return
      }
      let requestId = payload["requestId"] as? String ?? "-"
      let method = payload["method"] as? String ?? "-"
      let ok = payload["ok"] as? Bool ?? false
      let code = payload["code"] as? String ?? "-"
      logUnityAvatar(
        "forward commandResult method=\(method) request=\(requestId) "
          + "ok=\(ok) code=\(code)"
      )
      self?.channel.invokeMethod("commandResult", arguments: payload)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepareView":
      if let arguments = call.arguments as? [String: Any],
         let presentationId = arguments["presentationId"] as? String,
         !presentationId.isEmpty {
        commandSink.requestPresentation(presentationId)
      }
      commandSink.attachToFlutterHost()
      completeCommand(call: call, result: result)
    case "releaseView":
      commandSink.detach()
      result(nil)
    case "loadAvatar":
      completeCommand(call: call, result: result)
    case "avatarArbiterCommand", "avatarArbiterReset":
      guard UnityAvatarArbiterPayload.isValidArguments(
        method: call.method,
        raw: call.arguments
      ) else {
        result(FlutterError(
          code: "invalid_unity_avatar_arbiter_command",
          message: "Unity Avatar arbiter command is invalid.",
          details: nil
        ))
        return
      }
      let payload = UnityAvatarCommandPayload.encode(
        method: call.method,
        arguments: call.arguments
      )
      guard commandSink.sendTicketed(method: call.method, arguments: payload) else {
        result(FlutterError(
          code: "not_ready",
          message: "Unity Avatar renderer is not ready.",
          details: nil
        ))
        return
      }
      result(nil)
    case "setBackgroundTaskWork":
      guard UnityBackgroundTaskWorkPayload.isValidArguments(call.arguments) else {
        result(FlutterError(code: "invalid_background_task_work",
                            message: "Background work command is invalid.", details: nil))
        return
      }
      let payload = UnityAvatarCommandPayload.encode(method: call.method, arguments: call.arguments)
      guard commandSink.sendTicketed(method: call.method, arguments: payload) else {
        result(FlutterError(code: "not_ready",
                            message: "Unity Avatar renderer is not ready.", details: nil))
        return
      }
      result(nil)
    case "enterAgentSpace", "leaveAgentSpace", "requestAgentSpaceMoveAtScreenPoint":
      guard UnityAgentSpacePayload.isValidArguments(method: call.method, raw: call.arguments) else {
        result(FlutterError(code: "invalid_agent_space_command",
                            message: "Agent Space command arguments are invalid.", details: nil))
        return
      }
      let payload = UnityAvatarCommandPayload.encode(method: call.method, arguments: call.arguments)
      guard commandSink.sendTicketed(method: call.method, arguments: payload) else {
        result(FlutterError(code: "not_ready",
                            message: "Unity Avatar renderer is not ready.", details: nil))
        return
      }
      result(nil)
    case "setExpression":
      completeCommand(call: call, result: result)
    case "setMouthOpen":
      completeCommand(call: call, result: result)
    case "setGaze":
      completeCommand(call: call, result: result)
    case "clearGaze":
      completeCommand(call: call, result: result)
    case "startLipSync":
      completeCommand(call: call, result: result)
    case "syncSpeechPlaybackClock", "setConversationPhase":
      completeCommand(call: call, result: result)
    case "startVisemeTimeline":
      completeCommand(call: call, result: result)
    case "stopLipSync":
      completeCommand(call: call, result: result)
    case "playPrimitive":
      completeCommand(call: call, result: result)
    case "playAnimationClip":
      completeCommand(call: call, result: result)
    case "reactToScreenTap":
      completeCommand(call: call, result: result)
    case "setHandIkTarget":
      completeCommand(call: call, result: result)
    case "setBodyPose":
      completeCommand(call: call, result: result)
    case "setLocalAvatarVisible", "setPhoneInteraction", "transitionPresence", "transitionLoginDoorway":
      completeCommand(call: call, result: result)
    case "playMotion":
      completeCommand(call: call, result: result)
    case "playMotionSequence":
      completeCommand(call: call, result: result)
    case "setFraming":
      completeCommand(call: call, result: result)
    case "setViewportSafeArea":
      completeCommand(call: call, result: result)
    case "setWorldTimeOfDay":
      completeCommand(call: call, result: result)
    case "setWorldCamera":
      completeCommand(call: call, result: result)
    case "pause":
      // UIScene owns native engine, focus and display-link transitions. Older
      // Flutter callers may still send these compatibility acknowledgements.
      result(nil)
    case "resume":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func completeCommand(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let payload = UnityAvatarCommandPayload.encode(
      method: call.method,
      arguments: call.arguments
    )
    commandSink.send(method: call.method, arguments: payload)
    result(nil)
  }

  deinit {
    if let commandResultObserver {
      NotificationCenter.default.removeObserver(commandResultObserver)
    }
  }
}

private struct StreamingAudioSinkFailure: LocalizedError {
  let code: String
  let message: String

  var errorDescription: String? { message }
}

final class StreamingAudioSinkPlugin {
  private let minimumSampleRate = 8_000.0
  private let maximumSampleRate = 192_000.0
  private let maximumPendingAudioBytes = 2 * 1024 * 1024
  private let maximumSessionSeconds: Int64 = 3_600
  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let engineConfigurationLock = NSLock()
  private var format: AVAudioFormat?
  private var isAttached = false
  private var pendingBufferCount = 0
  private var pendingAudioFrameCount: Int64 = 0
  private var pendingAudioByteCount = 0
  private var scheduledAudioFrameCount: Int64 = 0
  private var completedAudioFrameCount: Int64 = 0
  private var lastReportedPlayedFrameCount: Int64 = 0
  private var playbackSampleTimeOrigin: Int64?
  private var playbackFrameOrigin: Int64 = 0
  private var pausedPlayedFrameCount: Int64?
  private var sessionAudioFrameLimit: Int64 = 0
  private var drainRequested = false
  private var isPaused = false
  private var activeGeneration: Int64?
  private var playbackIncarnation: Int64 = 0
  private var pendingDrainResult: FlutterResult?
  private var pendingDrainTimeout: DispatchWorkItem?
  private var audioSessionInterruptionObserver: NSObjectProtocol?
  private var engineConfigurationObserver: NSObjectProtocol?
  private var engineConfigurationInvalidated = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    audioSessionInterruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handleAudioSessionInterruption(notification)
    }
    engineConfigurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      self?.setEngineConfigurationInvalidated(true)
      // AVFAudio posts this notification on an internal queue. Finish that
      // callback before stopping/resetting the engine to avoid its documented
      // synchronous teardown deadlock.
      DispatchQueue.main.async { [weak self] in
        self?.handleEngineConfigurationChange()
      }
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let args = call.arguments as? [String: Any]
      guard let generation = exactPositiveJSONInteger(
        args?["generation"], maximum: 9_007_199_254_740_991
      ) else {
        result(FlutterError(code: "invalid_generation", message: "start expects a positive generation", details: nil))
        return
      }
      let sampleRate = args?["sampleRate"] as? Double
        ?? Double(args?["sampleRate"] as? Int ?? 24000)
      let channelCount = args?["channels"] as? Int ?? 1
      guard channelCount >= 1, channelCount <= 2 else {
        result(FlutterError(code: "invalid_audio_format", message: "start expects mono or stereo PCM", details: nil))
        return
      }
      let channels = AVAudioChannelCount(channelCount)
      do {
        try start(
          sampleRate: sampleRate,
          channels: channels,
          generation: generation,
          voiceProcessingCaptureActive: args?["voiceProcessingCaptureActive"] as? Bool ?? false
        )
        result(receipt(generation: generation, terminal: "started"))
      } catch {
        stopImmediately(resetEngine: true, terminal: "cancelled")
        result(FlutterError(code: "audio_start_failed", message: error.localizedDescription, details: nil))
      }
    case "write":
      let args = call.arguments as? [String: Any]
      guard let generation = exactPositiveJSONInteger(
        args?["generation"], maximum: 9_007_199_254_740_991
      ), let data = pcmData(from: args?["pcm"]) else {
        result(FlutterError(code: "invalid_pcm", message: "write expects Uint8List PCM data", details: nil))
        return
      }
      guard activeGeneration == generation else {
        result(FlutterError(code: "stale_audio_generation", message: "write generation is no longer active", details: nil))
        return
      }
      do {
        try write(data: data, generation: generation)
        result(receipt(generation: generation, terminal: "accepted"))
      } catch {
        let failure = error as? StreamingAudioSinkFailure
        result(FlutterError(
          code: failure?.code ?? "audio_write_failed",
          message: failure?.message ?? error.localizedDescription,
          details: nil
        ))
      }
    case "pause":
      let args = call.arguments as? [String: Any]
      guard let generation = exactPositiveJSONInteger(
        args?["generation"], maximum: 9_007_199_254_740_991
      ) else {
        result(FlutterError(code: "invalid_generation", message: "pause expects a positive generation", details: nil))
        return
      }
      pause(generation: generation, result: result)
    case "resume":
      let args = call.arguments as? [String: Any]
      guard let generation = exactPositiveJSONInteger(
        args?["generation"], maximum: 9_007_199_254_740_991
      ) else {
        result(FlutterError(code: "invalid_generation", message: "resume expects a positive generation", details: nil))
        return
      }
      resume(generation: generation, result: result)
    case "position":
      let args = call.arguments as? [String: Any]
      guard let generation = exactPositiveJSONInteger(
        args?["generation"], maximum: 9_007_199_254_740_991
      ) else {
        result(FlutterError(code: "invalid_generation", message: "position expects a positive generation", details: nil))
        return
      }
      position(generation: generation, result: result)
    case "stop":
      let args = call.arguments as? [String: Any]
      guard let generation = exactPositiveJSONInteger(
        args?["generation"], maximum: 9_007_199_254_740_991
      ) else {
        result(FlutterError(code: "invalid_generation", message: "stop expects a positive generation", details: nil))
        return
      }
      stop(
        drain: args?["drain"] as? Bool ?? true,
        generation: generation,
        result: result
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(
    sampleRate: Double,
    channels: AVAudioChannelCount,
    generation: Int64,
    voiceProcessingCaptureActive: Bool
  ) throws {
    stopImmediately(resetEngine: true, terminal: "cancelled")
    guard sampleRate.isFinite,
          sampleRate >= minimumSampleRate,
          sampleRate <= maximumSampleRate,
          sampleRate.rounded(.towardZero) == sampleRate,
          channels >= 1,
          channels <= 2 else {
      throw StreamingAudioSinkFailure(
        code: "invalid_audio_format",
        message: "start expects 8-192 kHz mono or stereo PCM"
      )
    }
    pendingBufferCount = 0
    pendingAudioFrameCount = 0
    pendingAudioByteCount = 0
    scheduledAudioFrameCount = 0
    completedAudioFrameCount = 0
    lastReportedPlayedFrameCount = 0
    playbackSampleTimeOrigin = nil
    playbackFrameOrigin = 0
    pausedPlayedFrameCount = nil
    sessionAudioFrameLimit = Int64(sampleRate) * maximumSessionSeconds
    drainRequested = false
    isPaused = false
    activeGeneration = generation
    let session = AVAudioSession.sharedInstance()
    // This output engine does not use Voice I/O. Forcing voiceChat without
    // active voice-processing capture can make PCM replies inaudible on iOS.
    // Preserve that profile only while record_ios actually runs authorized
    // echo-cancelled capture; ordinary recording still uses the default mode.
    let mode: AVAudioSession.Mode = voiceProcessingCaptureActive ? .voiceChat : .default
    try session.setCategory(
      .playAndRecord,
      mode: mode,
      options: [.defaultToSpeaker, .duckOthers]
    )
    try session.setActive(true)

    guard let audioFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: channels,
      interleaved: true
    ) else {
      throw NSError(domain: "StreamingAudioSink", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "failed to create PCM format"
      ])
    }
    format = audioFormat
    if !isAttached {
      engine.attach(player)
      isAttached = true
    }
    engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
    setEngineConfigurationInvalidated(false)
    engine.prepare()
    try engine.start()
    player.play()
  }

  private func write(data: Data, generation: Int64) throws {
    guard activeGeneration == generation,
          let audioFormat = format,
          engine.isRunning else {
      throw NSError(domain: "StreamingAudioSink", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "streaming audio generation is not active"
      ])
    }
    guard !drainRequested, pendingDrainResult == nil else {
      throw StreamingAudioSinkFailure(
        code: "audio_draining",
        message: "streaming audio is already draining"
      )
    }
    let incarnation = playbackIncarnation
    let bytesPerFrame = Int(audioFormat.streamDescription.pointee.mBytesPerFrame)
    let byteCount = data.count
    guard bytesPerFrame > 0, !data.isEmpty, data.count % bytesPerFrame == 0 else {
      throw NSError(domain: "StreamingAudioSink", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "PCM data must contain complete sample frames"
      ])
    }
    guard byteCount <= maximumPendingAudioBytes,
          pendingAudioByteCount <= maximumPendingAudioBytes - byteCount else {
      throw StreamingAudioSinkFailure(
        code: "audio_backpressure",
        message: "streaming audio pending queue is full"
      )
    }
    let frameCount = Int64(byteCount / bytesPerFrame)
    guard frameCount <= sessionAudioFrameLimit - scheduledAudioFrameCount else {
      throw StreamingAudioSinkFailure(
        code: "audio_session_limit",
        message: "streaming audio session exceeded its frame limit"
      )
    }
    let frames = AVAudioFrameCount(frameCount)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames) else {
      throw NSError(domain: "StreamingAudioSink", code: 4, userInfo: [
        NSLocalizedDescriptionKey: "failed to allocate PCM buffer"
      ])
    }
    buffer.frameLength = frames
    let copied = data.withUnsafeBytes { rawBuffer -> Bool in
      guard let src = rawBuffer.bindMemory(to: Int16.self).baseAddress,
            let dst = buffer.int16ChannelData?[0] else {
        return false
      }
      dst.update(from: src, count: data.count / MemoryLayout<Int16>.size)
      return true
    }
    guard copied else {
      throw NSError(domain: "StreamingAudioSink", code: 5, userInfo: [
        NSLocalizedDescriptionKey: "failed to copy PCM buffer"
      ])
    }
    if pendingBufferCount == 0 {
      reanchorPlaybackCursor(
        at: max(completedAudioFrameCount, lastReportedPlayedFrameCount)
      )
    }
    pendingBufferCount += 1
    pendingAudioFrameCount += Int64(frames)
    pendingAudioByteCount += byteCount
    scheduledAudioFrameCount += Int64(frames)
    player.scheduleBuffer(
      buffer,
      completionCallbackType: .dataPlayedBack
    ) { [weak self] completionType in
      DispatchQueue.main.async {
        guard let self,
              self.activeGeneration == generation,
              self.playbackIncarnation == incarnation else { return }
        guard completionType == .dataPlayedBack,
              !self.isEngineConfigurationInvalidated(),
              self.engine.isRunning,
              (self.player.isPlaying || self.isPaused) else {
          self.stopImmediately(resetEngine: true, terminal: "cancelled")
          return
        }
        self.pendingBufferCount = max(0, self.pendingBufferCount - 1)
        self.pendingAudioFrameCount = max(
          0,
          self.pendingAudioFrameCount - Int64(frames)
        )
        self.pendingAudioByteCount = max(
          0,
          self.pendingAudioByteCount - byteCount
        )
        self.completedAudioFrameCount = min(
          self.scheduledAudioFrameCount,
          self.completedAudioFrameCount + Int64(frames)
        )
        self.lastReportedPlayedFrameCount = max(
          self.lastReportedPlayedFrameCount,
          self.completedAudioFrameCount
        )
        self.finishDrainIfNeeded(
          generation: generation,
          incarnation: incarnation
        )
      }
    }
    if !isPaused && !player.isPlaying {
      player.play()
    }
  }

  private func pause(
    generation: Int64,
    result: @escaping FlutterResult
  ) {
    guard activeGeneration == generation else {
      result(FlutterError(code: "stale_audio_generation", message: "pause generation is no longer active", details: nil))
      return
    }
    if !isPaused {
      let playedBeforePause = observedPlayedAudioFrameCount()
      player.pause()
      let frozenPlayedFrames = max(
        playedBeforePause,
        observedPlayedAudioFrameCount()
      )
      isPaused = true
      pausedPlayedFrameCount = frozenPlayedFrames
      pendingDrainTimeout?.cancel()
      pendingDrainTimeout = nil
    }
    result(receipt(generation: generation, terminal: "paused"))
  }

  private func resume(
    generation: Int64,
    result: @escaping FlutterResult
  ) {
    guard activeGeneration == generation else {
      result(FlutterError(code: "stale_audio_generation", message: "resume generation is no longer active", details: nil))
      return
    }
    guard isPaused else {
      result(FlutterError(code: "audio_resume_failed", message: "streaming audio player is not paused", details: nil))
      return
    }
    let resumeFrame = max(
      completedAudioFrameCount,
      pausedPlayedFrameCount ?? lastReportedPlayedFrameCount
    )
    isPaused = false
    pausedPlayedFrameCount = nil
    player.play()
    reanchorPlaybackCursor(at: resumeFrame)
    if drainRequested {
      scheduleDrainTimeout(
        generation: generation,
        incarnation: playbackIncarnation
      )
      finishDrainIfNeeded(
        generation: generation,
        incarnation: playbackIncarnation
      )
    }
    result(receipt(generation: generation, terminal: "resumed"))
  }

  private func position(
    generation: Int64,
    result: @escaping FlutterResult
  ) {
    guard activeGeneration == generation else {
      result(FlutterError(code: "stale_audio_generation", message: "position generation is no longer active", details: nil))
      return
    }
    result(positionReceipt(
      generation: generation,
      playedFrames: observedPlayedAudioFrameCount(),
      acceptedFrames: scheduledAudioFrameCount
    ))
  }

  private func stop(
    drain: Bool,
    generation: Int64,
    result: @escaping FlutterResult
  ) {
    guard activeGeneration == generation else {
      result(receipt(generation: generation, terminal: "cancelled"))
      return
    }
    if drain {
      guard pendingDrainResult == nil else {
        result(FlutterError(code: "audio_drain_pending", message: "a drain is already pending", details: nil))
        return
      }
      pendingDrainResult = result
      drainRequested = true
      if !isPaused {
        scheduleDrainTimeout(
          generation: generation,
          incarnation: playbackIncarnation
        )
      }
      finishDrainIfNeeded(
        generation: generation,
        incarnation: playbackIncarnation
      )
      return
    }
    stopImmediately(resetEngine: true, terminal: "cancelled")
    result(receipt(generation: generation, terminal: "cancelled"))
  }

  private func finishDrainIfNeeded(
    generation: Int64,
    incarnation: Int64
  ) {
    guard drainRequested,
          pendingBufferCount == 0,
          activeGeneration == generation,
          playbackIncarnation == incarnation else { return }
    stopImmediately(resetEngine: false, terminal: "completed")
  }

  private func scheduleDrainTimeout(
    generation: Int64,
    incarnation: Int64
  ) {
    pendingDrainTimeout?.cancel()
    let sampleRate = max(1, format?.sampleRate ?? 24_000)
    let remainingSeconds = Double(pendingAudioFrameCount) / sampleRate
    let timeoutSeconds = min(max(remainingSeconds + 5, 5), 600)
    let timeout = DispatchWorkItem { [weak self] in
      guard let self,
            self.drainRequested,
            self.activeGeneration == generation,
            self.playbackIncarnation == incarnation,
            let result = self.pendingDrainResult else { return }
      self.pendingDrainResult = nil
      self.drainRequested = false
      self.stopImmediately(resetEngine: true, terminal: "cancelled")
      result(FlutterError(
        code: "audio_drain_timeout",
        message: "AVAudioPlayerNode did not complete the drain marker",
        details: nil
      ))
    }
    pendingDrainTimeout = timeout
    DispatchQueue.main.asyncAfter(
      deadline: .now() + timeoutSeconds,
      execute: timeout
    )
  }

  private func stopImmediately(resetEngine: Bool, terminal: String) {
    let retiringGeneration = activeGeneration
    let drainResult = pendingDrainResult
    let playerWasPaused = isPaused
    pendingDrainResult = nil
    pendingDrainTimeout?.cancel()
    pendingDrainTimeout = nil
    drainRequested = false
    isPaused = false
    pendingBufferCount = 0
    pendingAudioFrameCount = 0
    pendingAudioByteCount = 0
    scheduledAudioFrameCount = 0
    completedAudioFrameCount = 0
    lastReportedPlayedFrameCount = 0
    playbackSampleTimeOrigin = nil
    playbackFrameOrigin = 0
    pausedPlayedFrameCount = nil
    sessionAudioFrameLimit = 0
    activeGeneration = nil
    playbackIncarnation &+= 1
    // A semantic takeover normally arrives after barge-in paused the node.
    // Explicitly stop that paused node so its scheduled buffers cannot resume
    // under a replacement generation when the engine is started again.
    if player.isPlaying || playerWasPaused {
      player.stop()
    }
    if engine.isRunning {
      engine.stop()
    }
    format = nil
    if resetEngine {
      engine.reset()
    }
    if let drainResult, let retiringGeneration {
      drainResult(receipt(generation: retiringGeneration, terminal: terminal))
    }
  }

  private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: rawType) == .began,
          activeGeneration != nil else { return }
    stopImmediately(resetEngine: true, terminal: "cancelled")
  }

  private func handleEngineConfigurationChange() {
    guard activeGeneration != nil else { return }
    stopImmediately(resetEngine: true, terminal: "cancelled")
  }

  private func setEngineConfigurationInvalidated(_ invalidated: Bool) {
    engineConfigurationLock.lock()
    engineConfigurationInvalidated = invalidated
    engineConfigurationLock.unlock()
  }

  private func isEngineConfigurationInvalidated() -> Bool {
    engineConfigurationLock.lock()
    defer { engineConfigurationLock.unlock() }
    return engineConfigurationInvalidated
  }

  private func currentPlayerSampleTime() -> Int64? {
    guard let renderTime = player.lastRenderTime,
          renderTime.isSampleTimeValid,
          let playerTime = player.playerTime(forNodeTime: renderTime),
          playerTime.isSampleTimeValid else { return nil }
    return max(0, Int64(playerTime.sampleTime))
  }

  private func reanchorPlaybackCursor(at frameCount: Int64) {
    playbackFrameOrigin = min(
      scheduledAudioFrameCount,
      max(0, frameCount)
    )
    playbackSampleTimeOrigin = currentPlayerSampleTime()
  }

  private func observedPlayedAudioFrameCount() -> Int64 {
    if isPaused, let pausedPlayedFrameCount {
      return min(scheduledAudioFrameCount, max(0, pausedPlayedFrameCount))
    }
    var observed = completedAudioFrameCount
    if let sampleTime = currentPlayerSampleTime() {
      if let sampleTimeOrigin = playbackSampleTimeOrigin,
         sampleTime >= sampleTimeOrigin {
        let remaining = max(0, scheduledAudioFrameCount - playbackFrameOrigin)
        observed = max(
          observed,
          playbackFrameOrigin + min(remaining, sampleTime - sampleTimeOrigin)
        )
      } else if playbackSampleTimeOrigin == nil {
        playbackFrameOrigin = min(
          scheduledAudioFrameCount,
          max(completedAudioFrameCount, lastReportedPlayedFrameCount)
        )
        playbackSampleTimeOrigin = sampleTime
      }
    }
    observed = min(
      scheduledAudioFrameCount,
      max(lastReportedPlayedFrameCount, max(0, observed))
    )
    lastReportedPlayedFrameCount = observed
    return observed
  }

  private func receipt(generation: Int64, terminal: String) -> [String: Any] {
    ["generation": generation, "terminal": terminal]
  }

  private func positionReceipt(
    generation: Int64,
    playedFrames: Int64,
    acceptedFrames: Int64
  ) -> [String: Any] {
    [
      "generation": generation,
      "playedFrames": playedFrames,
      "acceptedFrames": acceptedFrames,
    ]
  }

  private func pcmData(from arguments: Any?) -> Data? {
    if let typed = arguments as? FlutterStandardTypedData {
      return typed.data
    }
    return arguments as? Data
  }

  deinit {
    if let audioSessionInterruptionObserver {
      NotificationCenter.default.removeObserver(audioSessionInterruptionObserver)
    }
    if let engineConfigurationObserver {
      NotificationCenter.default.removeObserver(engineConfigurationObserver)
    }
    channel.setMethodCallHandler(nil)
  }
}

final class NativeAsrPlugin {
  private let channel: FlutterMethodChannel
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var speechRecognizer: SFSpeechRecognizer?
  private var externalAudio = false
  private var shouldDeactivateAudioSessionOnCleanup = false
  private var activeRequestId: Int64?
  private var latestStartRequestId: Int64?
  private let externalAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16000,
    channels: 1,
    interleaved: false
  )!

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(SFSpeechRecognizer(locale: Locale.current)?.isAvailable == true)
    case "start":
      let args = call.arguments as? [String: Any]
      guard let requestId = (args?["requestId"] as? NSNumber)?.int64Value else {
        result(FlutterError(code: "invalid_request", message: "requestId is required", details: nil))
        return
      }
      start(
        locale: args?["locale"] as? String,
        externalAudio: false,
        requestId: requestId,
        result: result
      )
    case "startExternal":
      let args = call.arguments as? [String: Any]
      guard let requestId = (args?["requestId"] as? NSNumber)?.int64Value else {
        result(FlutterError(code: "invalid_request", message: "requestId is required", details: nil))
        return
      }
      start(
        locale: args?["locale"] as? String,
        externalAudio: true,
        requestId: requestId,
        result: result
      )
    case "appendPcm16":
      guard let data = pcmData(from: call.arguments) else {
        result(FlutterError(code: "invalid_pcm", message: "appendPcm16 expects Uint8List PCM data", details: nil))
        return
      }
      appendExternalPcm16(data)
      result(nil)
    case "stop":
      stop(sendCancel: false)
      result(nil)
    case "cancel":
      stop(sendCancel: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(
    locale: String?,
    externalAudio: Bool,
    requestId: Int64,
    result: @escaping FlutterResult
  ) {
    stop(sendCancel: true)
    latestStartRequestId = requestId
    SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
      guard let self else { return }
      DispatchQueue.main.async {
        guard self.latestStartRequestId == requestId else {
          result(false)
          return
        }
        guard speechStatus == .authorized else {
          self.latestStartRequestId = nil
          self.emitCallback(
            "onError",
            requestId: requestId,
            value: "speech recognition permission denied"
          )
          result(false)
          return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { micGranted in
          DispatchQueue.main.async {
            guard self.latestStartRequestId == requestId else {
              result(false)
              return
            }
            guard micGranted else {
              self.latestStartRequestId = nil
              self.emitCallback(
                "onError",
                requestId: requestId,
                value: "microphone permission denied"
              )
              result(false)
              return
            }
            do {
              try self.startRecognition(
                locale: locale,
                externalAudio: externalAudio,
                requestId: requestId
              )
              result(true)
            } catch {
              self.stop(sendCancel: true)
              self.emitCallback(
                "onError",
                requestId: requestId,
                value: error.localizedDescription
              )
              result(false)
            }
          }
        }
      }
    }
  }

  private func startRecognition(
    locale: String?,
    externalAudio: Bool,
    requestId: Int64
  ) throws {
    activeRequestId = requestId
    self.externalAudio = externalAudio
    shouldDeactivateAudioSessionOnCleanup = !externalAudio
    let localeIdentifier = locale?.isEmpty == false ? locale! : Locale.current.identifier
    speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    guard speechRecognizer?.isAvailable == true else {
      throw NSError(domain: "NativeAsr", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "speech recognizer unavailable"
      ])
    }

    guard #available(iOS 13.0, *), speechRecognizer?.supportsOnDeviceRecognition == true else {
      throw NSError(domain: "NativeAsr", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "on-device speech recognition unavailable"
      ])
    }

    if !externalAudio {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    recognitionRequest = request

    if !externalAudio {
      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      input.removeTap(onBus: 0)
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
        self?.recognitionRequest?.append(buffer)
      }

      audioEngine.prepare()
      try audioEngine.start()
    }
    emitCallback("onListening", requestId: requestId, value: true)

    recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] value, error in
      guard let self else { return }
      guard self.activeRequestId == requestId else { return }
      if let value {
        let text = value.bestTranscription.formattedString
        self.emitCallback(
          value.isFinal ? "onFinal" : "onPartial",
          requestId: requestId,
          value: text
        )
        if value.isFinal {
          self.finishRecognitionAfterFinal()
          if self.activeRequestId == requestId {
            self.activeRequestId = nil
            self.latestStartRequestId = nil
          }
        }
      }
      if let error {
        guard self.activeRequestId == requestId else { return }
        self.emitCallback(
          "onError",
          requestId: requestId,
          value: error.localizedDescription
        )
        self.recognitionTask?.cancel()
        self.cleanupRecognition(
          deactivateAudioSession: self.shouldDeactivateAudioSessionOnCleanup
        )
        if self.activeRequestId == requestId {
          self.activeRequestId = nil
          self.latestStartRequestId = nil
        }
      }
    }
  }

  private func appendExternalPcm16(_ data: Data) {
    guard externalAudio, let request = recognitionRequest else { return }
    let frameCount = data.count / MemoryLayout<Int16>.size
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(
            pcmFormat: externalAudioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
          ),
          let dst = buffer.floatChannelData?[0] else {
      return
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    data.withUnsafeBytes { rawBuffer in
      guard let src = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
        return
      }
      for i in 0..<frameCount {
        dst[i] = Float(Int16(littleEndian: src[i])) / 32768.0
      }
    }
    request.append(buffer)
  }

  private func stop(sendCancel: Bool) {
    latestStartRequestId = nil
    let requestId = activeRequestId
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    if sendCancel {
      recognitionTask?.cancel()
      cleanupRecognition(deactivateAudioSession: shouldDeactivateAudioSessionOnCleanup)
      activeRequestId = nil
    } else {
      recognitionRequest?.endAudio()
      if let requestId {
        emitCallback("onListening", requestId: requestId, value: false)
      }
      if shouldDeactivateAudioSessionOnCleanup {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        shouldDeactivateAudioSessionOnCleanup = false
      }
      externalAudio = false
    }
  }

  private func emitCallback(_ method: String, requestId: Int64, value: Any) {
    let valueKey: String
    switch method {
    case "onListening": valueKey = "listening"
    case "onError": valueKey = "error"
    default: valueKey = "text"
    }
    channel.invokeMethod(
      method,
      arguments: ["requestId": requestId, valueKey: value]
    )
  }

  private func finishRecognitionAfterFinal() {
    cleanupRecognition(deactivateAudioSession: shouldDeactivateAudioSessionOnCleanup)
  }

  private func cleanupRecognition(deactivateAudioSession: Bool) {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    recognitionTask = nil
    recognitionRequest = nil
    externalAudio = false
    shouldDeactivateAudioSessionOnCleanup = false
    if let activeRequestId {
      emitCallback("onListening", requestId: activeRequestId, value: false)
    }
    if deactivateAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func pcmData(from arguments: Any?) -> Data? {
    if let typed = arguments as? FlutterStandardTypedData {
      return typed.data
    }
    return arguments as? Data
  }
}
