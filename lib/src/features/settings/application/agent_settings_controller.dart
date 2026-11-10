import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/agent_pipeline_runtime_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/services/theme_service.dart';

class AgentSettingsController extends AppController {
  final AgentCoreController _core = appServices.find<AgentCoreController>();
  final LLMConfigController _llm = appServices.find<LLMConfigController>();
  bool get localEdition => _llm.localEdition;
  late final LLMConfigAccountSession _llmSession;
  final LocaleConfigService _localeSvc = appServices
      .find<LocaleConfigService>();
  final MaasoAgentModeService _agentMode = appServices
      .find<MaasoAgentModeService>();
  final AuthSessionService _auth = appServices.find<AuthSessionService>();
  final AccountSessionLifecycleService _accountLifecycle = appServices
      .find<AccountSessionLifecycleService>();
  final AvatarConfigService _avatars = appServices.find<AvatarConfigService>();

  /// UI-bound locale + voice — saved on tap.
  late final Rx<AppLocale> selectedLocale;
  late final RxString selectedVoice;
  late final Rx<ThemeModePreference> selectedThemeMode;
  late final RxBool volcRealtimeChatOnly;
  late final Rx<AgentPipelineMode> pipelineMode;

  /// Voice presets ("音色") for the on-device Supertonic 3 engine, mapped to
  /// its speaker ids. The bundled build ships 10 voices: sids 0–4 are female
  /// (F1–F5), sids 5–9 are male (M1–M5). Automatic follows the selected avatar.
  static const voiceOptions = <_VoicePreset>[
    _VoicePreset(id: 'auto', label: 'settings.voice_default', index: 0),
    _VoicePreset(id: 'f1', label: 'settings.voice_female', index: 1, sid: 0),
    _VoicePreset(id: 'f2', label: 'settings.voice_female', index: 2, sid: 1),
    _VoicePreset(id: 'f3', label: 'settings.voice_female', index: 3, sid: 2),
    _VoicePreset(id: 'f4', label: 'settings.voice_female', index: 4, sid: 3),
    _VoicePreset(id: 'f5', label: 'settings.voice_female', index: 5, sid: 4),
    _VoicePreset(id: 'm1', label: 'settings.voice_male', index: 1, sid: 5),
    _VoicePreset(id: 'm2', label: 'settings.voice_male', index: 2, sid: 6),
    _VoicePreset(id: 'm3', label: 'settings.voice_male', index: 3, sid: 7),
    _VoicePreset(id: 'm4', label: 'settings.voice_male', index: 4, sid: 8),
    _VoicePreset(id: 'm5', label: 'settings.voice_male', index: 5, sid: 9),
  ];

  late final TextEditingController apiKey;
  late final TextEditingController baseUrl;
  late final TextEditingController model;
  late final RxBool cloudEnabled;
  final cloudSaveFailed = false.obs;

  late final TextEditingController nickname;
  late final TextEditingController bio;
  late final TextEditingController catchphrase;

  final bluetoothEnabled = false.obs;
  final connectedDevice = Rxn<String>();

  /// Sentinel provider name for a hand-entered endpoint that matches none of
  /// the presets — keeps the dropdown valid without forcing the user onto a
  /// preset.
  static const customProviderName = 'Custom';

  // Volcano Engine (Doubao) is the default provider; its model id is itself a
  // fixed dropdown of console inference endpoints.  Other providers keep a
  // free-text model field (empty [models]).
  static const providerPresets = <ProviderPreset>[
    ProviderPreset(
      "Volcano Engine (Doubao)",
      LLMDefaults.baseUrl,
      LLMDefaults.model,
      models: [
        LLMDefaults.seedEvolving,
        LLMDefaults.glm53Flash,
        LLMDefaults.deepseek41Flash,
        LLMDefaults.deepseek4Pro,
      ],
    ),
    ProviderPreset("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"),
    ProviderPreset(
      "Anthropic",
      "https://api.anthropic.com/v1",
      "claude-haiku-4-5",
    ),
    ProviderPreset(
      "Gemini",
      "https://generativelanguage.googleapis.com/v1beta",
      "gemini-2.0-flash",
    ),
    ProviderPreset("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat"),
    ProviderPreset(
      "通义千问 / Qwen",
      "https://dashscope.aliyuncs.com/compatible-mode/v1",
      "qwen-plus",
    ),
    ProviderPreset(
      "Kimi / Moonshot",
      "https://api.moonshot.cn/v1",
      "kimi-k3.1-pro",
    ),
    ProviderPreset("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", "glm-5.3"),
    ProviderPreset(
      "SiliconFlow",
      "https://api.siliconflow.cn/v1",
      "Qwen/Qwen3-8B",
    ),
    ProviderPreset(
      "Groq",
      "https://api.groq.com/openai/v1",
      "openai/gpt-oss-120b",
    ),
    ProviderPreset("Ollama (Local)", "http://127.0.0.1:11434/v1", "qwen3:8b"),
    ProviderPreset(customProviderName, "", ""),
  ];

  final providers = providerPresets;

  /// Currently-selected provider name driving both dropdowns.
  late final RxString selectedProviderName;

  /// Currently-selected model id (mirrors the [model] field for the dropdown
  /// path; the [model] controller stays the single source saved to storage).
  late final RxString selectedModelId;

  // Debounce timers so typing in a field auto-saves once the user pauses,
  // instead of writing storage / probing the cloud on every keystroke.
  Timer? _cloudDebounce;
  Future<void>? _lastCloudSave;
  int _cloudSaveGeneration = 0;
  bool _closed = false;
  static const _debounce = Duration(milliseconds: 600);

  @override
  void onInit() {
    super.onInit();
    _llmSession = _llm.requireActiveAccountSession();
    apiKey = TextEditingController(text: _llm.apiKey.value);
    baseUrl = TextEditingController(text: _llm.baseUrl.value);
    model = TextEditingController(text: _llm.model.value);
    cloudEnabled = _llm.cloudEnabled.value.obs;
    selectedProviderName = _providerNameFor(_llm.baseUrl.value).obs;
    selectedModelId = _llm.model.value.obs;
    // Auto-save the cloud config when any of its fields change (debounced).
    apiKey.addListener(_scheduleCloudSave);
    baseUrl.addListener(_scheduleCloudSave);
    model.addListener(_scheduleCloudSave);

    selectedLocale = _localeSvc.locale.value.obs;
    selectedVoice = _currentVoiceId().obs;
    volcRealtimeChatOnly = _agentMode.volcRealtimeChatOnly;
    pipelineMode = _agentMode.pipelineMode;
    selectedThemeMode = ThemeModePreference.fromKey(
      _core.profile.value?.themeMode ?? _core.profile.value?.themeBrightness,
    ).obs;

    final p = _core.profile.value;
    nickname = TextEditingController(text: p?.nickname ?? "");
    bio = TextEditingController(text: p?.bio ?? "");
    catchphrase = TextEditingController(text: p?.catchphrase ?? "");
  }

  /// Map the engine's persisted speaker id back to a preset id for the UI.
  String _currentVoiceId() {
    if (_avatars.voicePreferences.followsAvatar.value) return 'auto';
    final sid = appServices.isRegistered<SherpaNeuralTts>()
        ? appServices.find<SherpaNeuralTts>().voiceSid.value
        : _avatars.voicePreferences.voiceSid.value;
    for (final v in voiceOptions) {
      if (v.sid == sid) return v.id;
    }
    return 'auto';
  }

  /// Live-apply locale immediately (no save button required) — most users
  /// expect a language switch to be instant.
  Future<void> setLocale(AppLocale next) async {
    final runtimeRegistry = appServices.maybeFind<AgentRuntimeRegistry>();
    runtimeRegistry?.invalidateInstalledSkillPrompts();
    selectedLocale.value = next;
    await _localeSvc.setLocale(next);
    if (runtimeRegistry != null) {
      await runtimeRegistry.refreshInstalledSkillPrompts(
        agentIds: <String>{
          if (_core.profile.value?.userId.trim().isNotEmpty == true)
            _core.profile.value!.userId
          else
            'self',
        },
      );
    }
  }

  /// Live-apply the chosen voice — push its Supertonic speaker id into the
  /// neural engine, which persists it and uses it on the next synthesis call.
  Future<void> setVoice(String id) async {
    selectedVoice.value = id;
    final preset = voiceOptions.firstWhere(
      (v) => v.id == id,
      orElse: () => voiceOptions.first,
    );
    if (preset.sid == null) {
      final selectedAvatar = _avatars.selected;
      await _avatars.voicePreferences.setFollowsAvatar(
        true,
        selectedGender: selectedAvatar.voiceGender,
        preferredSid: selectedAvatar.preferredVoiceSid,
      );
      return;
    }
    await _avatars.voicePreferences.selectManualSid(preset.sid!);
  }

  Future<void> setThemeMode(ThemeModePreference next) async {
    if (_closed || !_llm.isAccountSessionActive(_llmSession)) {
      throw StateError('No active account owns this appearance setting.');
    }
    final profile = _core.profile.value;
    if (profile == null) {
      throw StateError('The account profile is not ready.');
    }
    final previous = selectedThemeMode.value;
    final theme = appServices.maybeFind<ThemeService>();
    selectedThemeMode.value = next;
    theme?.setMode(next);
    try {
      await _core.updateProfile(
        profile.copyWith(
          themeMode: next.key,
          themeBrightness: next == ThemeModePreference.dark ? 'dark' : 'light',
        ),
      );
    } catch (_) {
      if (!_closed && _llm.isAccountSessionActive(_llmSession)) {
        selectedThemeMode.value = previous;
        if (identical(theme, appServices.maybeFind<ThemeService>())) {
          theme?.setMode(previous);
        }
      }
      rethrow;
    }
  }

  Future<void> setVolcRealtimeChatOnly(bool value) async {
    await _agentMode.setVolcRealtimeChatOnly(value);
  }

  Future<void> setPipelineMode(AgentPipelineMode value) async {
    final pipeline = appServices.maybeFind<AgentPipelineRuntimeService>();
    final pipelineSession = pipeline?.activeAccountSession;
    await _agentMode.setPipelineMode(value);
    final effectiveMode = _agentMode.pipelineMode.value;
    if (pipeline != null && pipelineSession != null) {
      await pipeline.refreshForMode(
        effectiveMode,
        accountSession: pipelineSession,
      );
    }
    if (pipeline == null ||
        pipelineSession == null ||
        !pipeline.isAccountSessionActive(pipelineSession)) {
      return;
    }
    if (effectiveMode == AgentPipelineMode.directCloud &&
        cloudEnabled.value &&
        !localEdition &&
        !appServices.isRegistered<CloudLLMHealthService>()) {
      appServices.put(CloudLLMHealthService());
    }
    if (_llm.isAccountSessionActive(_llmSession)) {
      _llm.activateCloudHealthForCurrentAccount(session: _llmSession);
    }
  }

  Future<void> logout() async {
    await _accountLifecycle.signOutAndUnmount();
    if (_auth.session.value != null) {
      throw StateError('Account session remained active after sign-out.');
    }
    appNavigation.go(AppRouteCatalog.login);
  }

  @override
  void onClose() {
    // Flush any pending debounced edits so leaving the page never loses the
    // last keystroke.
    if (_cloudDebounce?.isActive ?? false) {
      _startCloudSave();
    }
    _closed = true;
    _cloudDebounce?.cancel();
    apiKey.dispose();
    baseUrl.dispose();
    model.dispose();
    nickname.dispose();
    bio.dispose();
    catchphrase.dispose();
    super.onClose();
  }

  /// The preset backing the current dropdown selection, or null for Custom.
  ProviderPreset? get currentProvider {
    for (final p in providers) {
      if (p.name == selectedProviderName.value) return p;
    }
    return null;
  }

  /// Fixed model ids for the selected provider (empty ⇒ free-text model).
  List<String> get currentModels => currentProvider?.models ?? const [];

  /// Match a stored base URL back to a provider name so the dropdown reflects
  /// the saved config; unknown endpoints map to [customProviderName].
  String _providerNameFor(String url) {
    final u = url.trim();
    for (final p in providers) {
      if (p.baseUrl == u) return p.name;
    }
    return customProviderName;
  }

  /// User picked a provider from the dropdown.  Custom leaves the fields
  /// untouched; a preset rewrites base URL + model to its defaults.
  void applyProvider(String name) {
    selectedProviderName.value = name;
    if (name == customProviderName) return;
    for (final p in providers) {
      if (p.name == name) {
        baseUrl.text = p.baseUrl;
        model.text = p.model;
        selectedModelId.value = p.model;
        return;
      }
    }
  }

  /// User picked a model id from the (provider-scoped) model dropdown.
  void selectModel(String id) {
    selectedModelId.value = id;
    model.text = id;
  }

  /// Manual "recheck" button — fire a fresh cloud connectivity probe now.
  Future<void> recheckCloudHealth() async {
    await _llm.recheckCloudHealth(session: _llmSession);
  }

  // ───────────────────────── auto-save ─────────────────────────
  // No "Save" button — everything persists on change. Text fields debounce;
  // toggles/dropdowns persist immediately.

  /// Toggle the cloud brain on/off and persist right away.
  void setCloudEnabled(bool v) {
    if (localEdition) return;
    cloudEnabled.value = v;
    _startCloudSave();
  }

  void _scheduleCloudSave() {
    _cloudDebounce?.cancel();
    _cloudDebounce = Timer(_debounce, () {
      _startCloudSave();
    });
  }

  Future<void> retryCloudSave() {
    _startCloudSave();
    return _lastCloudSave ?? Future<void>.value();
  }

  void _startCloudSave() {
    final generation = ++_cloudSaveGeneration;
    final operation = _persistCloud().then<void>(
      (_) {
        if (!_closed && generation == _cloudSaveGeneration) {
          cloudSaveFailed.value = false;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        Log.w(
          '[Settings] direct-cloud configuration save failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (!_closed && generation == _cloudSaveGeneration) {
          cloudSaveFailed.value = true;
        }
      },
    );
    _lastCloudSave = operation;
    unawaited(operation);
  }

  Future<void> _persistCloud() async {
    _cloudDebounce?.cancel();
    if (!_llm.isAccountSessionActive(_llmSession)) return;
    try {
      if (!localEdition &&
          cloudEnabled.value &&
          !appServices.isRegistered<CloudLLMHealthService>()) {
        appServices.put(CloudLLMHealthService());
      }
      await _llm.saveConfig(
        apiKey.text,
        baseUrl.text,
        model.text,
        session: _llmSession,
        enabled: localEdition ? null : cloudEnabled.value,
      );
      if (localEdition && _llm.isAccountSessionActive(_llmSession)) {
        cloudEnabled.value = _llm.cloudUsable;
      }
    } on StateError {
      // Route disposal can race the synchronous account fence. A stale page
      // has nothing left to persist and must not surface an unhandled Future.
      if (!_llm.isAccountSessionActive(_llmSession)) return;
      rethrow;
    }
  }

  Future<void> scanHardware() async {
    bluetoothEnabled.value = true;
    await Future.delayed(const Duration(seconds: 1));
    connectedDevice.value = "Maaso-Paw-001";
    showAppGlassNotice(
      title: 'settings.connected_title'.tr,
      message: "Maaso-Paw-001",
      icon: Icons.bluetooth_connected_rounded,
    );
  }
}

class ProviderPreset {
  final String name;
  final String baseUrl;
  final String model;

  /// Fixed model ids shown as a dropdown for this provider.  Empty means the
  /// model is a free-text field (the provider has no curated list).
  final List<String> models;
  const ProviderPreset(
    this.name,
    this.baseUrl,
    this.model, {
    this.models = const [],
  });
}

class _VoicePreset {
  final String id;

  /// i18n key for the gender label (e.g. 女声 / Female).
  final String label;

  /// 1-based number shown after the gender label (女声 1, 女声 2, …).
  final int index;

  /// Supertonic speaker id this preset selects.
  final int? sid;
  const _VoicePreset({
    required this.id,
    required this.label,
    required this.index,
    this.sid,
  });

  /// Display name for the dropdown, e.g. "女声 2".
  String get display => index > 0 ? '${label.tr} $index' : label.tr;
}

/// Public alias so the settings page can reference the type.
typedef VoicePreset = _VoicePreset;
