import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HomePresentationMode {
  chat,
  avatar;

  static HomePresentationMode fromKey(Object? key) =>
      key == 'chat' ? HomePresentationMode.chat : HomePresentationMode.avatar;
}

/// Device-local Home presentation, restored before Home is constructed.
/// Runtime availability changes its effective presentation, never the choice
/// saved by the user.
class HomePresentationPreferenceService extends AppService {
  static const storageKey = 'home.presentation_mode';

  final Rx<HomePresentationMode> mode = HomePresentationMode.avatar.obs;
  SharedPreferences? _preferences;
  Future<void> _writes = Future<void>.value();
  Future<HomePresentationPreferenceService>? _loading;

  Future<HomePresentationPreferenceService> load() =>
      _loading ??= _loadPreference();

  Future<HomePresentationPreferenceService> _loadPreference() async {
    final preferences = await SharedPreferences.getInstance();
    _preferences = preferences;
    mode.value = HomePresentationMode.fromKey(preferences.get(storageKey));
    return this;
  }

  HomePresentationMode resolve({required bool avatarAvailable}) =>
      avatarAvailable ? mode.value : HomePresentationMode.chat;

  Future<void> setMode(HomePresentationMode next) {
    final write = _writes.then((_) async {
      if (isClosed) throw StateError('home_presentation_service_closed');
      await load();
      if (next == mode.value) return;
      final saved = await _preferences!.setString(storageKey, next.name);
      if (!saved) throw StateError('home_presentation_save_failed');
      if (!isClosed) mode.value = next;
    });
    // A failed save must remain retryable without poisoning later choices.
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}
