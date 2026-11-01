import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Renders [AlertEvent]s the AI fires through the alert skill.
///
/// Severity mapping:
///  • info    → bottom snackbar, light haptic, auto-dismiss
///  • warning → top banner with yellow theme + medium haptic
///  • urgent  → fullscreen red flash + center modal + heavy haptic,
///              requires user dismiss unless durationMs > 0
///
/// We coalesce: if a new alert arrives while one is showing, the new one
/// replaces it (the AI's latest intent wins).
class AlertOverlayService extends AppService {
  StreamSubscription? _sub;

  @override
  void onInit() {
    super.onInit();
    _sub = EventBus().on<AlertEvent>().listen(_onAlert);
  }

  @override
  void onClose() {
    _sub?.cancel();
    super.onClose();
  }

  void _onAlert(AlertEvent e) {
    _fireHaptic(e.haptic);

    switch (e.level) {
      case 'urgent':
        _showUrgent(e);
        break;
      case 'warning':
        _showWarning(e);
        break;
      case 'info':
      default:
        _showInfo(e);
    }
  }

  // ——————————————————— haptic ———————————————————

  void _fireHaptic(String level) {
    switch (level) {
      case 'heavy':
        HapticFeedback.heavyImpact();
        Future.delayed(
          const Duration(milliseconds: 110),
          HapticFeedback.heavyImpact,
        );
        break;
      case 'medium':
        HapticFeedback.mediumImpact();
        break;
      case 'light':
        HapticFeedback.lightImpact();
        break;
      case 'none':
      default:
        break;
    }
  }

  // ——————————————————— render variants ———————————————————

  void _showInfo(AlertEvent e) {
    final color = _parseHex(e.color) ?? ColorConstant.primaryColor;
    appNavigation.showSnackBar(
      title: e.title,
      message: e.message ?? '',
      snackPosition: AppSnackPosition.top,
      backgroundColor: color,
      colorText: Colors.white,
      margin: const EdgeInsets.all(16),
      borderRadius: 16,
      duration: e.durationMs > 0
          ? Duration(milliseconds: e.durationMs)
          : const Duration(seconds: 4),
      icon: const Padding(
        padding: EdgeInsets.only(left: 8),
        child: Icon(Icons.info_outline, color: Colors.white, size: 22),
      ),
    );
  }

  void _showWarning(AlertEvent e) {
    final color = _parseHex(e.color) ?? const Color(0xFFEF6C00);
    appNavigation.showSnackBar(
      title: e.title,
      message: e.message ?? '',
      snackPosition: AppSnackPosition.top,
      backgroundColor: color,
      colorText: Colors.white,
      margin: const EdgeInsets.all(12),
      borderRadius: 14,
      duration: e.durationMs > 0
          ? Duration(milliseconds: e.durationMs)
          : const Duration(seconds: 5),
      icon: const Padding(
        padding: EdgeInsets.only(left: 8),
        child: Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
      ),
    );
  }

  void _showUrgent(AlertEvent e) {
    // Dismiss any existing alert dialog first.
    if (appNavigation.isDialogOpen) appNavigation.pop();

    final color = _parseHex(e.color) ?? const Color(0xFFE53935);
    appNavigation.dialog(
      _UrgentAlert(event: e, themeColor: color),
      barrierDismissible: e.durationMs > 0,
      barrierColor: e.flash
          ? color.withValues(alpha: 0.45)
          : Colors.black.withValues(alpha: 0.55),
    );

    if (e.durationMs > 0) {
      Future.delayed(Duration(milliseconds: e.durationMs), () {
        if (appNavigation.isDialogOpen) appNavigation.pop();
      });
    }
  }

  Color? _parseHex(String? hex) {
    if (hex == null) return null;
    final s = hex.startsWith('#') ? hex.substring(1) : hex;
    if (s.length != 6) return null;
    try {
      return Color(int.parse('FF$s', radix: 16));
    } catch (_) {
      return null;
    }
  }
}

class _UrgentAlert extends StatefulWidget {
  final AlertEvent event;
  final Color themeColor;
  const _UrgentAlert({required this.event, required this.themeColor});

  @override
  State<_UrgentAlert> createState() => _UrgentAlertState();
}

class _UrgentAlertState extends State<_UrgentAlert>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.maybeOf(context);
    final reduceFeedback =
        media?.disableAnimations == true ||
        media?.highContrast == true ||
        media?.accessibleNavigation == true;
    if (widget.event.flash && !reduceFeedback) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final accent = glass.copyWith(accent: widget.themeColor);
    return Center(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) {
          // Explicit alert attention feedback ends with expiry or dismissal.
          return Opacity(opacity: 1 - _pulse.value * .04, child: child);
        },
        child: AppGlassSurface(
          role: AppGlassSurfaceRole.transient,
          cornerRadius: MaasoGlassTheme.surfaceRadius,
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: accent.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.notifications_active_rounded,
                  color: accent.accentText,
                  size: 30,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                widget.event.title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: glass.foregroundPrimary,
                ),
              ),
              if (widget.event.message != null &&
                  widget.event.message!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  widget.event.message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: glass.foregroundSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () =>
                      appNavigation.isDialogOpen ? appNavigation.pop() : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent.action,
                    foregroundColor: accent.onAction,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'common.got_it'.tr,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
