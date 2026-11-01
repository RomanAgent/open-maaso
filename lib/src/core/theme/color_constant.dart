import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

class ColorConstant {
  // Compatibility aliases for the Maaso White Frost theme.
  static const Color primaryColor = MaasoFrostTokens.action;
  static const Color secondaryColor = MaasoFrostTokens.lightAccent;
  static const Color accentColor = MaasoFrostTokens.lightAccent;
  static const Color skyColor = Color(0xFF64D2FF);
  static const Color violetColor = Color(0xFFAF52DE);
  static const Color limeColor = Color(0xFF30D158);
  static const Color backgroundColor = MaasoFrostTokens.lightCanvas;
  static const Color surfaceColor = MaasoFrostTokens.lightSurface;
  static const Color cardColor = MaasoFrostTokens.lightSurface;
  static const Color errorColor = MaasoFrostTokens.lightDanger;
  static const Color successColor = MaasoFrostTokens.lightSuccess;

  // ChatGPT-style neutral foregrounds. Keep text free from the active accent
  // hue so changing the agent theme never tints ordinary copy.
  static const Color textPrimary = MaasoFrostTokens.lightTextPrimary;
  static const Color textSecondary = MaasoFrostTokens.lightTextSecondary;
  static const Color divider = MaasoFrostTokens.lightDivider;

  // Avatar palette
  static const Color avatarBody = Color(0xFFFFD7BE);
  static const Color avatarBodyShade = Color(0xFFF5B894);
  static const Color avatarCheek = Color(0xFFFFB0A0);
  static const Color avatarEye = Color(0xFF2A1A12);
}

/// Default cloud (BYOK) endpoint + model used on a fresh install, before the
/// user has saved anything in Settings.  Default provider is Volcano Engine
/// (Doubao); the proxy, config controller, and health probe all read these so
/// the "default provider" lives in exactly one place.
class LLMDefaults {
  static const String baseUrl = "https://ark.cn-beijing.volces.com/api/v3";
  static const String doubaoSeed21Turbo = "doubao-seed-2-1-turbo-260628";
  static const String doubaoSeed21Pro = "doubao-seed-2-1-pro-260628";
  static const String seedEvolving = 'doubao-seed-evolving';
  static const String glm53Flash = 'glm-5-3-flash-260828';
  static const String deepseek41Flash = 'deepseek-v4-1-flash-260910';
  static const String deepseek4Pro = 'deepseek-v4-pro-ga-260813';
  static const String model = seedEvolving;
}

class GlobalConstant {
  static const String appName = "Maaso";
  static const String isarDbName = "maaso_db";

  // Storage Keys
  static const String keyLlmApiKey = "llm_api_key";
  static const String keyLlmBaseUrl = "llm_base_url";
  static const String keyLlmModel = "llm_model";
  static const String keyLlmCloudEnabled = "llm_cloud_enabled";
  static const String keyMaasoEnvironment = "maaso_environment";
  static const String keyMaasoAccessToken = "maaso_access_token";
  static const String keyMaasoRefreshToken = "maaso_refresh_token";
  static const String keyMaasoAccountUuid = "maaso_account_uuid";
  static const String keyMaasoAccessTokenExpiresAt =
      "maaso_access_token_expires_at";
  static const String keyAdvancedFeaturesEnabled = "advanced_features_enabled";
  static const String keyAgentPipelineMode = "agent_pipeline_mode";
  static const String keyVolcRealtimeChatOnly = "volc_realtime_chat_only";
  static const String keyIsAgentInitialized = "is_agent_initialized";

  // i18n + TTS voice
  static const String keyAppLocale = "app_locale"; // 'en' | 'zh' | ...
  static const String keyTtsVoice =
      "tts_voice_style"; // 'F1' / 'F2' / 'M1' / ...
  static const String skillKeyTtsVoice =
      "TTS_VOICE_STYLE"; // AgentConfig naming, read by the TTS bridge
}
