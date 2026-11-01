/// A platform-neutral window rectangle persisted by the desktop shell.
class DesktopWindowBounds {
  const DesktopWindowBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopWindowBounds &&
          left == other.left &&
          top == other.top &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'DesktopWindowBounds($left, $top, $width, $height)';
}

/// The OS-facing operations required by the companion window state machine.
///
/// Implementations own platform details such as frameless styles, taskbar
/// visibility, screen clamping, and the compact pet size. Keeping those
/// details behind this interface lets the application state remain testable.
abstract interface class DesktopWindowGateway {
  bool get isSupported;

  Future<DesktopWindowBounds> readBounds();

  Future<void> enterPetMode();

  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds});

  Future<void> startDragging();
}

/// Optional capability for platforms that keep the pet in a second native
/// window while the Flutter router remains in the normal application window.
abstract interface class IndependentDesktopPetWindowGateway {
  bool get supportsIndependentPetWindow;
}

/// Optional phone-sized authentication presentation for the main app window.
/// The independent desktop pet keeps its own bounds and native lifecycle.
abstract interface class DesktopAuthWindowGateway {
  Future<void> enterAuthMode();
}

final class UnsupportedDesktopWindowGateway implements DesktopWindowGateway {
  const UnsupportedDesktopWindowGateway();

  @override
  bool get isSupported => false;

  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 0, top: 0, width: 0, height: 0);

  @override
  Future<void> enterPetMode() async {}

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {}

  @override
  Future<void> startDragging() async {}
}
