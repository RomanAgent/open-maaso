import 'dart:math' as math;

import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';

final class DesktopWindowPlacement {
  const DesktopWindowPlacement._();

  static const double petWidth = 320;
  static const double petHeight = 420;
  static const double edgeMargin = 12;
  static const double minimumAppWidth = 720;
  static const double minimumAppHeight = 520;
  static const double authWidth = 393;
  static const double authHeight = 852;

  /// Uses a phone content viewport plus native titlebar, reduced uniformly only
  /// when the current display's work area cannot hold it at full size.
  static DesktopWindowBounds authBounds({
    required DesktopWindowBounds current,
    required List<DesktopWindowBounds> visibleDisplays,
    required DesktopWindowBounds primaryDisplay,
    double titleBarHeight = 0,
  }) {
    final display = _displayFor(current, visibleDisplays) ?? primaryDisplay;
    final availableWidth = math.max(1.0, display.width - edgeMargin * 2);
    final availableHeight = math.max(1.0, display.height - edgeMargin * 2);
    final chromeHeight = titleBarHeight.clamp(0.0, availableHeight - 1);
    final scale = math.min(
      1.0,
      math.min(
        availableWidth / authWidth,
        (availableHeight - chromeHeight) / authHeight,
      ),
    );
    final width = authWidth * scale;
    final height = authHeight * scale + chromeHeight;
    return DesktopWindowBounds(
      left: display.left + (display.width - width) / 2,
      top: display.top + (display.height - height) / 2,
      width: width,
      height: height,
    );
  }

  static DesktopWindowBounds petBounds({
    required DesktopWindowBounds current,
    required List<DesktopWindowBounds> visibleDisplays,
    required DesktopWindowBounds primaryDisplay,
  }) {
    final display = _displayFor(current, visibleDisplays) ?? primaryDisplay;
    final maximumLeft = math.max(
      display.left + edgeMargin,
      display.left + display.width - petWidth - edgeMargin,
    );
    final maximumTop = math.max(
      display.top + edgeMargin,
      display.top + display.height - petHeight - edgeMargin,
    );
    return DesktopWindowBounds(
      left: current.left.clamp(display.left + edgeMargin, maximumLeft),
      top: current.top.clamp(display.top + edgeMargin, maximumTop),
      width: petWidth,
      height: petHeight,
    );
  }

  static DesktopWindowBounds appBounds({
    DesktopWindowBounds? requested,
    List<DesktopWindowBounds> visibleDisplays = const [],
    required DesktopWindowBounds primaryDisplay,
  }) {
    final display = requested == null
        ? primaryDisplay
        : _displayFor(requested, visibleDisplays) ?? primaryDisplay;
    final availableWidth = math.max(1.0, display.width);
    final availableHeight = math.max(1.0, display.height);
    final width = math.min(
      math.max(requested?.width ?? 1100, minimumAppWidth),
      availableWidth,
    );
    final height = math.min(
      math.max(requested?.height ?? 760, minimumAppHeight),
      availableHeight,
    );
    final requestedCenterIsVisible =
        requested != null && _contains(display, _centerOf(requested));
    final left = requestedCenterIsVisible
        ? requested.left.clamp(
            display.left,
            display.left + availableWidth - width,
          )
        : display.left + (availableWidth - width) / 2;
    final top = requestedCenterIsVisible
        ? requested.top.clamp(
            display.top,
            display.top + availableHeight - height,
          )
        : display.top + (availableHeight - height) / 2;
    return DesktopWindowBounds(
      left: left,
      top: top,
      width: width,
      height: height,
    );
  }

  static DesktopWindowBounds? _displayFor(
    DesktopWindowBounds window,
    List<DesktopWindowBounds> displays,
  ) {
    final center = _centerOf(window);
    for (final display in displays) {
      if (_contains(display, center)) return display;
    }
    return null;
  }

  static ({double x, double y}) _centerOf(DesktopWindowBounds bounds) =>
      (x: bounds.left + bounds.width / 2, y: bounds.top + bounds.height / 2);

  static bool _contains(
    DesktopWindowBounds bounds,
    ({double x, double y}) point,
  ) =>
      point.x >= bounds.left &&
      point.x <= bounds.left + bounds.width &&
      point.y >= bounds.top &&
      point.y <= bounds.top + bounds.height;
}
