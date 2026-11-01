import 'dart:async';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';

final class MethodChannelMacOSDesktopCompanionHostGateway
    implements DesktopCompanionHostGateway {
  static const String channelName = 'maaso/desktop_companion';
  static const MethodChannel _channel = MethodChannel(channelName);
  static MethodChannelMacOSDesktopCompanionHostGateway? _handlerOwner;

  FutureOr<void> Function(String id)? _onMenuSelected;
  FutureOr<void> Function(DesktopCompanionHostCommand command)? _onCommand;
  FutureOr<void> Function(Offset? gaze)? _onGazeChanged;
  FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)?
  _onInteraction;
  int? _activeInteractionGeneration;
  int _lastInteractionGeneration = 0;
  int _lastInteractionTimestampMs = -1;
  bool _initialized = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize({
    required FutureOr<void> Function(String id) onMenuSelected,
    required FutureOr<void> Function(DesktopCompanionHostCommand command)
    onCommand,
    required FutureOr<void> Function(Offset? gaze) onGazeChanged,
    required FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)
    onInteraction,
  }) async {
    _onMenuSelected = onMenuSelected;
    _onCommand = onCommand;
    _onGazeChanged = onGazeChanged;
    _onInteraction = onInteraction;
    _resetInteractionOrdering();
    if (_initialized) return;
    _initialized = true;
    _handlerOwner = this;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  @override
  Future<void> configureMenu(List<DesktopCompanionHostMenuItem> items) =>
      _channel.invokeMethod<void>('configureMenu', <String, Object?>{
        'items': items
            .map(
              (item) => <String, Object?>{
                'id': item.id,
                'label': item.label,
                'enabled': item.enabled,
              },
            )
            .toList(growable: false),
        'openAppLabel': _text(zh: '打开 Maaso', en: 'Open Maaso'),
        'hidePetLabel': _text(zh: '隐藏桌宠', en: 'Hide Desktop Pet'),
        'quitLabel': _text(zh: '退出 Maaso', en: 'Quit Maaso'),
      });

  @override
  Future<void> configurePresentation(
    DesktopCompanionPresentationConfigV1 config,
  ) async {
    try {
      await _channel.invokeMethod<void>(
        'configurePresentation',
        config.toJson(),
      );
    } on MissingPluginException {
      // A rolling upgrade may briefly pair new Dart code with an older native
      // runner. Keep the existing native defaults instead of hiding the pet.
    }
  }

  static String _text({required String zh, required String en}) =>
      AppLocalization.locale.languageCode == 'zh' ? zh : en;

  @override
  Future<void> show({required int interactionGeneration}) {
    if (interactionGeneration < DesktopAvatarInteractionV1.minimumGeneration ||
        interactionGeneration > DesktopAvatarInteractionV1.maximumGeneration) {
      throw ArgumentError.value(interactionGeneration, 'interactionGeneration');
    }
    _activeInteractionGeneration = interactionGeneration;
    _lastInteractionGeneration = interactionGeneration;
    _lastInteractionTimestampMs = -1;
    return _channel.invokeMethod<void>('show', <String, Object>{
      'interactionGeneration': interactionGeneration,
    });
  }

  @override
  Future<void> hide() {
    _activeInteractionGeneration = null;
    return _channel.invokeMethod<void>('hide');
  }

  @override
  Future<void> showBubble(String text) => _channel.invokeMethod<void>(
    'showBubble',
    <String, Object?>{'text': text},
  );

  @override
  Future<void> clearBubble() => _channel.invokeMethod<void>('clearBubble');

  Future<void> _handleNativeCall(MethodCall call) async {
    final arguments = call.arguments is Map
        ? Map<Object?, Object?>.from(call.arguments as Map)
        : const <Object?, Object?>{};
    switch (call.method) {
      case 'menuSelected':
        final id = arguments['id']?.toString().trim() ?? '';
        if (id.isNotEmpty) await _onMenuSelected?.call(id);
        return;
      case 'command':
        final command = switch (arguments['id']?.toString()) {
          'openApp' => DesktopCompanionHostCommand.openApp,
          'hidePet' => DesktopCompanionHostCommand.hidePet,
          'hostUnavailable' => DesktopCompanionHostCommand.hostUnavailable,
          'quit' => DesktopCompanionHostCommand.quit,
          _ => null,
        };
        if (command != null) await _onCommand?.call(command);
        return;
      case 'gazeChanged':
        if (arguments['active'] != true) {
          await _onGazeChanged?.call(null);
          return;
        }
        final x = arguments['x'];
        final y = arguments['y'];
        if (x is num && y is num) {
          await _onGazeChanged?.call(
            Offset(
              x.toDouble().clamp(-1.0, 1.0).toDouble(),
              y.toDouble().clamp(-1.0, 1.0).toDouble(),
            ),
          );
        }
        return;
      case 'avatarInteraction':
        final interaction = DesktopAvatarInteractionV1.tryFromJson(arguments);
        if (interaction == null || !_acceptInteractionOrdering(interaction)) {
          return;
        }
        await _onInteraction?.call(interaction);
        return;
      default:
        throw MissingPluginException(
          'Unsupported native desktop companion callback: ${call.method}',
        );
    }
  }

  bool _acceptInteractionOrdering(DesktopAvatarInteractionV1 interaction) {
    if (interaction.generation != _activeInteractionGeneration ||
        interaction.generation != _lastInteractionGeneration) {
      return false;
    }
    if (interaction.timestampMs <= _lastInteractionTimestampMs) return false;
    _lastInteractionTimestampMs = interaction.timestampMs;
    return true;
  }

  void _resetInteractionOrdering() {
    _activeInteractionGeneration = null;
    _lastInteractionGeneration = 0;
    _lastInteractionTimestampMs = -1;
  }

  @override
  Future<void> dispose() async {
    _onMenuSelected = null;
    _onCommand = null;
    _onGazeChanged = null;
    _onInteraction = null;
    _resetInteractionOrdering();
    if (!_initialized) return;
    _initialized = false;
    if (!identical(_handlerOwner, this)) return;
    try {
      await _channel.invokeMethod<void>('dispose');
    } finally {
      if (identical(_handlerOwner, this)) {
        _handlerOwner = null;
        _channel.setMethodCallHandler(null);
      }
    }
  }
}
