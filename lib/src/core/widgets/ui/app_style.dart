import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

/// The visual style the app renders in.
///
/// Maaso now uses a single iOS-style app skin. The enum stays so persisted
/// profile rows can continue to store a stable style key.
///
/// Orthogonal to the *theme* (brightness + accent), resolved separately by
/// ThemeService / AppPalette from the appearance settings and profile.
enum AgentUiStyle {
  adventureWorld('adventure_world');

  const AgentUiStyle(this.key);

  /// Stable string persisted in [AgentProfile.uiStyle].
  final String key;

  /// Tolerant parse: old rows and bad input fall back to adventure world.
  static AgentUiStyle fromKey(String? key) => AgentUiStyle.adventureWorld;

  String get label => 'style.adventure_world'.tr;
}

/// App-wide holder for the *active* UI style.
class UiStyleService extends AppService {
  final Rx<AgentUiStyle> style = AgentUiStyle.adventureWorld.obs;

  void setStyle(AgentUiStyle next) => style.value = AgentUiStyle.adventureWorld;

  /// Convenience for callers holding the persisted string key.
  void setKey(String? key) => style.value = AgentUiStyle.adventureWorld;
}

/// Rebuilds [builder] whenever the active [AgentUiStyle] changes.
///
/// Use this inside adaptive components instead of touching [UiStyleService]
/// directly — it falls back to [AgentUiStyle.adventureWorld] when the service
/// isn't registered (e.g. in widget tests) so components stay self-contained.
class StyleBuilder extends StatelessWidget {
  const StyleBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, AgentUiStyle style) builder;

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<UiStyleService>()) {
      return builder(context, AgentUiStyle.adventureWorld);
    }
    final svc = appServices.find<UiStyleService>();
    return AppReactiveBuilder(() => builder(context, svc.style.value));
  }
}
