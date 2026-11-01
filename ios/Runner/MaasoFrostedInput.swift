import Flutter
import UIKit

/// Decorative background only. UIKit owns blur sampling across the native
/// Unity surface; Flutter retains the text field, buttons, focus and gestures.
final class MaasoFrostedInputFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let values = args as? [String: Any] ?? [:]
    let dark = values["dark"] as? Bool ?? false
    let requestedRadius = (values["cornerRadius"] as? NSNumber)?.doubleValue ?? 28
    let radius = requestedRadius.isFinite ? max(0, min(requestedRadius, 999)) : 28
    return MaasoFrostedInputView(
      frame: frame, dark: dark, radius: radius,
      group: values["group"] as? Bool ?? false,
      messenger: messenger, viewId: viewId
    )
  }
}

private final class MaasoFrostedInputView: NSObject, FlutterPlatformView {
  private let background: MaasoFrostedInputMaterial
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect, dark: Bool, radius: Double, group: Bool,
    messenger: FlutterBinaryMessenger, viewId: Int64
  ) {
    background = MaasoFrostedInputMaterial(
      frame: frame, dark: dark, radius: radius, group: group
    )
    channel = FlutterMethodChannel(name: "maaso/frosted_input/\(viewId)", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "regions", let values = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.background.updateRegions(values)
      result(nil)
    }
  }

  func view() -> UIView { background }

  deinit { channel.setMethodCallHandler(nil) }
}

private final class MaasoFrostedInputMaterial: UIView {
  private let dark: Bool
  private let group: Bool
  private let effectView = UIVisualEffectView()
  private let regionMask = UIView()
  private let regionShapes = CAShapeLayer()
  private let edgeGradient = CAGradientLayer()
  private let userTintShapes = CAShapeLayer()
  private var regions: [[String: Any]] = []
  private var visibility: CGFloat = 1
  private var topFade: CGFloat = 0
  private var bottomFade: CGFloat = 0

  init(frame: CGRect, dark: Bool, radius: Double, group: Bool) {
    self.dark = dark
    self.group = group
    super.init(frame: frame)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    isOpaque = false
    layer.cornerRadius = CGFloat(radius)
    layer.cornerCurve = .continuous
    clipsToBounds = true
    effectView.isUserInteractionEnabled = false
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(effectView)
    if group {
      // Mask the effect itself, never its superview. A single sampler serves
      // every visible bubble; text and controls remain in Flutter.
      regionMask.layer.addSublayer(regionShapes)
      regionMask.layer.mask = edgeGradient
      effectView.mask = regionMask
      userTintShapes.fillColor = (dark
        ? UIColor(red: 231 / 255, green: 233 / 255, blue: 237 / 255, alpha: 0.96)
        : UIColor(red: 36 / 255, green: 39 / 255, blue: 43 / 255, alpha: 0.96)).cgColor
      effectView.contentView.layer.addSublayer(userTintShapes)
    }
    updateMaterial()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateMaterial),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil
    )
  }

  required init?(coder: NSCoder) { nil }

  deinit { NotificationCenter.default.removeObserver(self) }

  override func layoutSubviews() {
    super.layoutSubviews()
    effectView.frame = bounds
    updateMask()
  }

  func updateRegions(_ values: [String: Any]) {
    guard group else { return }
    regions = Array((values["regions"] as? [[String: Any]] ?? []).prefix(64))
    visibility = scalar(values["opacity"], fallback: 1, lower: 0, upper: 1)
    topFade = scalar(values["topFade"], lower: 0, upper: 1000)
    bottomFade = scalar(values["bottomFade"], lower: 0, upper: 1000)
    updateMask()
  }

  private func scalar(
    _ value: Any?, fallback: CGFloat = 0, lower: CGFloat = -100000, upper: CGFloat = 100000
  ) -> CGFloat {
    guard let number = value as? NSNumber, number.doubleValue.isFinite else { return fallback }
    return min(upper, max(lower, CGFloat(number.doubleValue)))
  }

  private func updateMask() {
    guard group else { return }
    let all = UIBezierPath()
    let userTint = UIBezierPath()
    for region in regions {
      let rect = CGRect(
        x: scalar(region["x"]), y: scalar(region["y"]),
        width: scalar(region["width"], lower: 0),
        height: scalar(region["height"], lower: 0)
      )
      guard !rect.isEmpty, rect.intersects(bounds) else { continue }
      let path = UIBezierPath(
        roundedRect: rect,
        cornerRadius: scalar(region["radius"], lower: 0, upper: min(rect.width, rect.height) / 2)
      )
      all.append(path)
      if region["userTint"] as? Bool == true { userTint.append(path) }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    effectView.isHidden = visibility <= 0 || all.isEmpty
    regionMask.frame = bounds
    regionShapes.frame = bounds
    regionShapes.path = all.cgPath
    regionShapes.fillColor = UIColor.white.withAlphaComponent(visibility).cgColor
    userTintShapes.frame = bounds
    userTintShapes.path = userTint.cgPath
    edgeGradient.frame = bounds
    let height = max(1, bounds.height)
    let top = min(0.49, topFade / height)
    let bottom = min(0.49, bottomFade / height)
    edgeGradient.startPoint = CGPoint(x: 0.5, y: 0)
    edgeGradient.endPoint = CGPoint(x: 0.5, y: 1)
    edgeGradient.colors = [
      UIColor.white.withAlphaComponent(topFade > 0 ? 0 : 1).cgColor,
      UIColor.white.cgColor, UIColor.white.cgColor,
      UIColor.white.withAlphaComponent(bottomFade > 0 ? 0 : 1).cgColor,
    ]
    edgeGradient.locations = [0, NSNumber(value: Double(top)), NSNumber(value: Double(1 - bottom)), 1]
    // UIVisualEffectView copies its mask into its internal effect layers.
    // Reassign after geometry/visibility changes so scrolling and waking do
    // not leave the first (initially empty) native mask behind.
    effectView.mask = nil
    effectView.mask = regionMask
    CATransaction.commit()
  }

  @objc private func updateMaterial() {
    let base = dark
      ? UIColor(red: 28 / 255, green: 32 / 255, blue: 38 / 255, alpha: 1)
      : UIColor.white
    if UIAccessibility.isReduceTransparencyEnabled {
      effectView.effect = nil
      backgroundColor = .clear
      effectView.contentView.backgroundColor = base
    } else {
      backgroundColor = .clear
      effectView.effect = UIBlurEffect(
        style: dark ? .systemThinMaterialDark : .systemThinMaterialLight
      )
      // Keep view alpha at 1: alpha on an effect view disables correct blur.
      effectView.contentView.backgroundColor = base.withAlphaComponent(0.06)
    }
  }
}
