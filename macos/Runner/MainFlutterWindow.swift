import Cocoa
import CoreLocation
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var desktopCompanionBridge: MacOSDesktopCompanionBridge?
  private var avatarPortalBridge: MacOSUnityAvatarPortalBridge?
  private var applicationExitChannel: FlutterMethodChannel?
  private var locationBridge: MaasoCityGeocoderBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.backgroundColor = NSColor.white
    flutterViewController.backgroundColor = NSColor.clear
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let registrar = flutterViewController.registrar(
      forPlugin: "MacOSUnityAvatarPortalBridge")
    applicationExitChannel = FlutterMethodChannel(
      name: "maaso/application_exit", binaryMessenger: registrar.messenger)
    applicationExitChannel?.setMethodCallHandler { call, result in
      MaasoApplicationExitPresentation.handle(call, result: result)
    }
    locationBridge = MaasoCityGeocoderBridge(channel: FlutterMethodChannel(
      name: "maaso/location", binaryMessenger: registrar.messenger))
    let companionBridge = MacOSDesktopCompanionBridge(registrar: registrar)
    desktopCompanionBridge = companionBridge
    avatarPortalBridge = MacOSUnityAvatarPortalBridge(
      registrar: registrar,
      desktopCompanionBridge: companionBridge)

    applyUnifiedTitlebarAppearance()
    super.awakeFromNib()
  }

  override func setIsVisible(_ flag: Bool) {
    guard !flag || !MaasoApplicationExitPresentation.isExiting else {
      super.orderOut(nil)
      return
    }
    if flag {
      applyUnifiedTitlebarAppearance()
    }
    super.setIsVisible(flag)
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    guard !MaasoApplicationExitPresentation.isExiting else {
      super.orderOut(nil)
      return
    }
    applyUnifiedTitlebarAppearance()
    super.makeKeyAndOrderFront(sender)
  }

  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    guard place == .out || !MaasoApplicationExitPresentation.isExiting else {
      super.order(.out, relativeTo: 0)
      return
    }
    super.order(place, relativeTo: otherWin)
  }

  private func applyUnifiedTitlebarAppearance() {
    // window_manager restores normal chrome before showing the app window.
    // Use its background color while retaining the native titlebar and buttons.
    titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) {
      titlebarSeparatorStyle = .none
    }
  }

  override func close() {
    guard desktopCompanionBridge?.isPetVisible != true else {
      orderOut(nil)
      return
    }
    super.close()
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
      forName: NSApplication.didResignActiveNotification,
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
    guard NSApp.isActive else {
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
        guard NSApp.isActive else {
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
