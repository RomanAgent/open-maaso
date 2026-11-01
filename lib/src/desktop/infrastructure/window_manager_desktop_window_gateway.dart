import 'dart:io';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_window_placement.dart';

final class WindowManagerDesktopWindowGateway
    implements
        DesktopWindowGateway,
        IndependentDesktopPetWindowGateway,
        DesktopAuthWindowGateway {
  const WindowManagerDesktopWindowGateway();

  @override
  bool get isSupported => Platform.isMacOS || Platform.isWindows;

  @override
  bool get supportsIndependentPetWindow =>
      Platform.isMacOS || Platform.isWindows;

  @override
  Future<DesktopWindowBounds> readBounds() async {
    await windowManager.ensureInitialized();
    return _fromRect(await windowManager.getBounds());
  }

  @override
  Future<void> enterPetMode() async {
    await windowManager.ensureInitialized();
    if (supportsIndependentPetWindow) {
      await windowManager.hide();
      return;
    }
    await _leaveExpandedState();
    final current = _fromRect(await windowManager.getBounds());
    final displays = await screenRetriever.getAllDisplays();
    final primary = await screenRetriever.getPrimaryDisplay();
    final target = DesktopWindowPlacement.petBounds(
      current: current,
      visibleDisplays: displays.map(_visibleBounds).toList(growable: false),
      primaryDisplay: _visibleBounds(primary),
    );

    await windowManager.setMinimumSize(Size.zero);
    await windowManager.setMaximumSize(
      const Size(
        DesktopWindowPlacement.petWidth,
        DesktopWindowPlacement.petHeight,
      ),
    );
    await windowManager.setMinimumSize(
      const Size(
        DesktopWindowPlacement.petWidth,
        DesktopWindowPlacement.petHeight,
      ),
    );
    await windowManager.setResizable(false);
    await windowManager.setAsFrameless();
    if (Platform.isMacOS) {
      // window_manager's macOS setAsFrameless() makes NSWindow opaque. The
      // hidden title-bar transition restores a non-opaque Flutter surface;
      // keep it before the clear background call.
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
    }
    await windowManager.setBackgroundColor(const Color(0x00000000));
    await windowManager.setHasShadow(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setOpacity(1);
    if (Platform.isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(
        true,
        visibleOnFullScreen: true,
      );
    }
    await windowManager.setBounds(_toRect(target));
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) =>
      _presentAppWindow(restoreBounds: restoreBounds);

  @override
  Future<void> enterAuthMode() => _presentAppWindow(authentication: true);

  Future<void> _presentAppWindow({
    DesktopWindowBounds? restoreBounds,
    bool authentication = false,
  }) async {
    await windowManager.ensureInitialized();
    await _leaveExpandedState();
    await windowManager.setMinimumSize(Size.zero);
    await windowManager.setMaximumSize(const Size(10000, 10000));
    await windowManager.setResizable(!authentication);
    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    final displays = (await screenRetriever.getAllDisplays())
        .map(_visibleBounds)
        .toList(growable: false);
    final primary = _visibleBounds(await screenRetriever.getPrimaryDisplay());
    // AppKit reports points; window_manager's Windows titlebar result is raw
    // pixels even though its getBounds/setBounds use logical pixels.
    final titleBarScale = Platform.isWindows
        ? windowManager.getDevicePixelRatio()
        : 1.0;
    final target = authentication
        ? DesktopWindowPlacement.authBounds(
            current: _fromRect(await windowManager.getBounds()),
            visibleDisplays: displays,
            primaryDisplay: primary,
            titleBarHeight:
                (await windowManager.getTitleBarHeight()) / titleBarScale,
          )
        : DesktopWindowPlacement.appBounds(
            requested: restoreBounds,
            visibleDisplays: displays,
            primaryDisplay: primary,
          );
    final targetSize = Size(target.width, target.height);
    await windowManager.setMinimumSize(
      authentication
          ? targetSize
          : Size(
              DesktopWindowPlacement.minimumAppWidth.clamp(1, target.width),
              DesktopWindowPlacement.minimumAppHeight.clamp(1, target.height),
            ),
    );
    if (authentication) await windowManager.setMaximumSize(targetSize);
    await windowManager.setBackgroundColor(ColorConstant.backgroundColor);
    await windowManager.setHasShadow(true);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    if (Platform.isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(false);
    }
    await windowManager.setBounds(_toRect(target));
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> startDragging() => windowManager.startDragging();

  Future<void> _leaveExpandedState() async {
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    }
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
  }

  static DesktopWindowBounds _visibleBounds(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return DesktopWindowBounds(
      left: position.dx,
      top: position.dy,
      width: size.width,
      height: size.height,
    );
  }

  static DesktopWindowBounds _fromRect(Rect rect) => DesktopWindowBounds(
    left: rect.left,
    top: rect.top,
    width: rect.width,
    height: rect.height,
  );

  static Rect _toRect(DesktopWindowBounds bounds) =>
      Rect.fromLTWH(bounds.left, bounds.top, bounds.width, bounds.height);
}
