import 'dart:convert';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/logger.dart';

/// User profile manager (User Persona).
class UserProfileManager {
  static final UserProfileManager _instance = UserProfileManager._internal();
  factory UserProfileManager() => _instance;
  UserProfileManager._internal();

  static const String _legacyKeyProfile = 'agent_user_profile';
  late SharedPreferences _prefs;
  bool _isInitialized = false;
  int _generation = 0;
  String _storageKeyPrefix = '';

  String get _keyProfile => _storageKeyPrefix.isEmpty
      ? _legacyKeyProfile
      : '$_storageKeyPrefix.preferences.$_legacyKeyProfile';

  // The user's profile traits (Key: dimension, Value: description).
  // e.g. {"occupation": "software engineer", "communication_style": "prefers short sentences, geeky"}
  Map<String, String> traits = {};

  Future<void> init({String storageKeyPrefix = ''}) async {
    final normalizedPrefix = storageKeyPrefix.trim();
    if (_isInitialized && _storageKeyPrefix == normalizedPrefix) return;
    final generation = ++_generation;
    traits = <String, String>{};
    _storageKeyPrefix = normalizedPrefix;
    final prefs = await SharedPreferences.getInstance();

    final String? profileJson = prefs.getString(_keyProfile);
    var loadedTraits = <String, String>{};
    if (profileJson != null) {
      loadedTraits = Map<String, String>.from(json.decode(profileJson));
    }
    if (generation != _generation || _storageKeyPrefix != normalizedPrefix) {
      throw StateError('UserProfileManager storage scope changed during init.');
    }

    _prefs = prefs;
    traits = loadedTraits;
    _isInitialized = true;
    Log.i('👤 [UserProfile] Profile loaded: $traits');
  }

  /// Drops the active account projection without deleting its persisted data.
  void deactivate({required String storageKeyPrefix}) {
    if (_storageKeyPrefix != storageKeyPrefix.trim()) return;
    _generation++;
    traits = <String, String>{};
    _storageKeyPrefix = '';
    _isInitialized = false;
  }

  /// 🌟 Update or add profile traits.
  Future<void> updateTraits(Map<String, String> newTraits) async {
    _requireActive();
    bool hasChanged = false;
    newTraits.forEach((key, value) {
      if (traits[key] != value) {
        traits[key] = value;
        hasChanged = true;
      }
    });

    if (hasChanged) {
      final key = _keyProfile;
      await _prefs.setString(key, json.encode(Map<String, String>.of(traits)));
      Log.i('✨ [UserProfile] User profile updated and persisted: $traits');
    }
  }

  void _requireActive() {
    if (!_isInitialized) {
      throw StateError('UserProfileManager is not active.');
    }
  }

  /// Assemble the prompt shown to the main Agent.
  String toPrompt({AppLocale? locale}) {
    if (traits.isEmpty) {
      return AgentPromptCatalog.text('legacy.profile.unknown', locale: locale);
    }

    final buffer = StringBuffer();
    buffer.writeln(
      AgentPromptCatalog.text('legacy.profile.header', locale: locale),
    );
    traits.forEach((key, value) {
      buffer.writeln(
        AgentPromptCatalog.text(
          'legacy.profile.entry',
          locale: locale,
          params: {'key': key, 'value': value},
        ),
      );
    });
    return buffer.toString();
  }
}
