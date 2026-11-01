import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/gaze_director.dart';

enum WidgetStageMode { compact, fullscreen }

/// Foreground stage for hub widgets/applets/blogs on the home screen.
///
/// The hub remains the source of truth; this only tracks which item the agent
/// has pulled out of the depth background and how large its window should be.
class WidgetStageController extends AppService {
  static const double avatarInputClearance = 112;

  final Rxn<AgentWidget> active = Rxn<AgentWidget>();
  final Rx<WidgetStageMode> mode = WidgetStageMode.compact.obs;
  final Rx<Offset?> compactTopLeft = Rx<Offset?>(null);
  final Rx<Offset> gazeTarget = Offset.zero.obs;

  void present(
    AgentWidget item, {
    WidgetStageMode nextMode = WidgetStageMode.compact,
  }) {
    active.value = item;
    mode.value = nextMode;
    compactTopLeft.value = null;
    gazeTarget.value = const Offset(0.65, 0.45);
  }

  void expand() {
    if (active.value == null) return;
    mode.value = WidgetStageMode.fullscreen;
  }

  void shrink() {
    if (active.value == null) return;
    mode.value = WidgetStageMode.compact;
  }

  void minimize() {
    active.value = null;
    mode.value = WidgetStageMode.compact;
    compactTopLeft.value = null;
    gazeTarget.value = Offset.zero;
    _pushWindowGaze(null); // hand the eyes back to face-follow / idle
  }

  void setCompactFrame({
    required Size viewport,
    required Size frameSize,
    required Offset desiredTopLeft,
  }) {
    final clamped = _clampTopLeft(viewport, frameSize, desiredTopLeft);
    compactTopLeft.value = clamped;
    _updateGaze(viewport, frameSize, clamped);
  }

  void moveCompactBy(
    Offset delta, {
    required Size viewport,
    required Size frameSize,
  }) {
    final current =
        compactTopLeft.value ??
        _defaultTopLeft(viewport: viewport, frameSize: frameSize);
    setCompactFrame(
      viewport: viewport,
      frameSize: frameSize,
      desiredTopLeft: current + delta,
    );
  }

  Offset compactTopLeftFor({required Size viewport, required Size frameSize}) {
    return compactTopLeft.value ??
        _defaultTopLeft(viewport: viewport, frameSize: frameSize);
  }

  Offset _defaultTopLeft({required Size viewport, required Size frameSize}) {
    return Offset(
      math.max(8, viewport.width - frameSize.width - 14),
      math.max(8, viewport.height * 0.18),
    );
  }

  Offset _clampTopLeft(Size viewport, Size frameSize, Offset desired) {
    final maxX = math.max(8.0, viewport.width - frameSize.width - 16);
    final maxY = math.max(8.0, viewport.height - frameSize.height - 96);
    return Offset(
      desired.dx.clamp(8.0, maxX).toDouble(),
      desired.dy.clamp(8.0, maxY).toDouble(),
    );
  }

  void _updateGaze(Size viewport, Size frameSize, Offset topLeft) {
    final center = topLeft + Offset(frameSize.width / 2, frameSize.height / 2);
    final cx = (center.dx / viewport.width).clamp(0.0, 1.0);
    final cy = (center.dy / viewport.height).clamp(0.0, 1.0);
    // Measure gaze from the same input-safe avatar anchor used by HomePage, so
    // the look-at direction stays aligned with the rendered model.
    final anchor = avatarHeadAnchorFraction(viewport: viewport);
    final dx = cx - anchor.dx;
    final dy = anchor.dy - cy; // screen-y grows downward; "look up" is positive
    final x = (dx * _gazeGainX).clamp(-1.0, 1.0);
    final y = (dy * _gazeGainY).clamp(-1.0, 1.0);
    gazeTarget.value = Offset(x.toDouble(), y.toDouble());
    _pushWindowGaze(gazeTarget.value);
  }

  /// Publish the window look-at to the [GazeDirector] (the single owner of the
  /// agent's ambient gaze). Guarded so the controller still works in unit tests
  /// where the director isn't registered.
  void _pushWindowGaze(Offset? dir) {
    if (appServices.isRegistered<GazeDirector>()) {
      appServices.find<GazeDirector>().setWindowGaze(dir);
    }
  }

  // How far the window has to travel from the eyes to drive a full eye/head
  // deflection. Higher = the agent reaches a big look-over with less drag, so
  // the follow reads clearly instead of as a subtle glance.
  static const double _gazeGainX = 2.2;
  static const double _gazeGainY = 2.2;

  static EdgeInsets avatarStageInsets({
    double topSafeInset = 0,
    double bottomSafeInset = 0,
    double keyboardInset = 0,
    double inputClearance = avatarInputClearance,
  }) {
    // The keyboard overlays the avatar stage. Tapping the composer should not
    // shrink or push the model upward; only the resting input bar is reserved.
    return EdgeInsets.only(
      top: math.max(0, topSafeInset.toDouble()),
      bottom:
          math.max(0, inputClearance.toDouble()) +
          math.max(0, bottomSafeInset.toDouble()),
    );
  }

  /// The avatar's head/eye position as a fraction of the full viewport.
  ///
  /// Mirrors home_page.dart's `_AvatarStage`: the avatar is centered inside a
  /// top/bottom safe stage that reserves the resting chat input but lets the
  /// keyboard overlay it. When a widget/card is foregrounded, it scales about
  /// the stage center instead of stepping into the lower-left corner.
  Offset avatarHeadAnchorFraction({
    Size? viewport,
    double topSafeInset = 0,
    double bottomSafeInset = 0,
    double keyboardInset = 0,
    double inputClearance = avatarInputClearance,
  }) {
    // Resting eye position within the full-screen avatar canvas.
    const restX = 0.5;
    const restY = 0.40;

    final scale = active.value == null
        ? 1.0
        : (mode.value == WidgetStageMode.fullscreen ? 0.46 : 0.58);
    final stageAnchor = Offset(
      0.5 + scale * (restX - 0.5),
      0.5 + scale * (restY - 0.5),
    );

    if (viewport == null || viewport.width <= 0 || viewport.height <= 0) {
      return stageAnchor;
    }

    final insets = avatarStageInsets(
      topSafeInset: topSafeInset,
      bottomSafeInset: bottomSafeInset,
      keyboardInset: keyboardInset,
      inputClearance: inputClearance,
    );
    final safeWidth = math.max(1.0, viewport.width - insets.horizontal);
    final safeHeight = math.max(1.0, viewport.height - insets.vertical);
    final x = (insets.left + stageAnchor.dx * safeWidth) / viewport.width;
    final y = (insets.top + stageAnchor.dy * safeHeight) / viewport.height;
    return Offset(x.clamp(0.0, 1.0).toDouble(), y.clamp(0.0, 1.0).toDouble());
  }
}
