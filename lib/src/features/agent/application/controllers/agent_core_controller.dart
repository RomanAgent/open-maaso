import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/widgets/ui/app_style.dart';
import 'package:maaso/src/core/services/agent_token_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/services/gender_generator.dart';
import 'package:maaso/src/core/services/voice_generator.dart';

class AgentCoreController extends AppController {
  final DBService _db = appServices.find<DBService>();
  Future<void>? _initialLoad;

  final Rxn<AgentProfile> profile = Rxn<AgentProfile>();
  final isInitialized = false.obs;

  bool get hasToken => (profile.value?.agentToken ?? '').isNotEmpty;
  String get agentToken => profile.value?.agentToken ?? '';
  bool get hasGender => (profile.value?.gender ?? '').isNotEmpty;

  @override
  void onInit() {
    super.onInit();
    unawaited(ensureLoaded());
  }

  /// Completes when the one startup profile load has fully projected its
  /// account-owned style and theme state.
  ///
  /// Account runtime mounting awaits this barrier before publishing the
  /// authenticated session, so a previous account cannot finish loading after
  /// a replacement graph has already mounted.
  Future<void> ensureLoaded() => _initialLoad ??= loadProfile();

  Future<void> loadProfile() async {
    var p = await _db.getSelfProfile();
    if (p != null) {
      await _migrateProfileIdentity(p);
    } else {
      p = await _bootstrapDefaultProfile();
    }
    profile.value = p;
    _syncUiStyle(p);
    _syncTheme(p);
    isInitialized.value = true;
  }

  /// Push the profile's persisted UI style into the app-wide [UiStyleService]
  /// so every adaptive component repaints in the active agent's style.
  void _syncUiStyle(AgentProfile p) {
    if (appServices.isRegistered<UiStyleService>()) {
      appServices.find<UiStyleService>().setKey(p.uiStyle);
    }
  }

  /// Push the profile's persisted theme (brightness + accent) into the
  /// app-wide [ThemeService] so [MaasoApp] rebuilds its ThemeData live.
  void _syncTheme(AgentProfile p) {
    if (appServices.isRegistered<ThemeService>()) {
      appServices.find<ThemeService>().setFromProfile(p);
    }
  }

  /// Auto-create a placeholder profile on first launch.  Nickname is left
  /// empty so [AgentBootController] knows to open with the "give me a name"
  /// flow; gender/voice/token get sensible defaults so the rest of the app
  /// (TTS, sync, avatar) can boot without nulls.
  Future<AgentProfile> _bootstrapDefaultProfile() async {
    final token = appServices.isRegistered<AgentTokenService>()
        ? (await appServices.find<AgentTokenService>().init()).agentToken.value
        : '';
    final gender = GenderGenerator().generate();
    final voiceId = VoiceGenerator().generateForGender(gender);
    final p = AgentProfile(
      userId: 'self',
      nickname: '',
      avatar: '',
      bio: '',
      personalityTraits: ['Curious', 'Warm'],
      catchphrase: '',
      agentToken: token,
      gender: gender,
      voiceId: voiceId,
      birthDate: DateTime.now(),
    );
    await _db.saveAgentProfile(p);
    return p;
  }

  Future<void> updateProfile(AgentProfile newProfile) async {
    await _db.saveAgentProfile(newProfile);
    profile.value = newProfile;
    _syncUiStyle(newProfile);
    _syncTheme(newProfile);
    isInitialized.value = true;
  }

  Future<void> birthAgent({
    required String agentToken,
    required String gender,
    required String voiceId,
    required String nickname,
  }) async {
    final newProfile = AgentProfile(
      userId: 'self',
      nickname: nickname,
      avatar: '',
      bio: '',
      personalityTraits: ['Curious', 'Warm'],
      catchphrase: '',
      agentToken: agentToken,
      gender: gender,
      voiceId: voiceId,
      birthDate: DateTime.now(),
    );
    await updateProfile(newProfile);
  }

  Future<void> _migrateProfileIdentity(AgentProfile p) async {
    var changed = false;
    if (p.userId != 'self') {
      p.userId = 'self';
      changed = true;
    }
    if (p.agentToken.trim().isEmpty &&
        appServices.isRegistered<AgentTokenService>()) {
      final tokenService = appServices.find<AgentTokenService>();
      await tokenService.init();
      p.agentToken = tokenService.agentToken.value;
      changed = true;
    }
    if (p.gender.trim().isEmpty) {
      p.gender = GenderGenerator().generate();
      changed = true;
    }
    if (p.voiceId.trim().isEmpty) {
      p.voiceId = VoiceGenerator().generateForGender(p.gender);
      changed = true;
    }
    if (p.birthDate == null) {
      p.birthDate = DateTime.now();
      changed = true;
    }
    if (changed) {
      await _db.saveAgentProfile(p);
    }
  }
}
