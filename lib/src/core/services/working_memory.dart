import 'package:maaso/src/features/agent/data/models/emotion_params.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

class WorkingMemory {
  String? currentUserInput;
  EmotionParams? currentEmotion;
  String? latestEnvCueType;
  Map<String, Object?>? envCuePayload;
  String? localBrainHint;
  String? localBrainEmotion;
  double? localBrainIntensity;
  Map<String, Object?>? sensorData;

  void clear() {
    currentUserInput = null;
    currentEmotion = null;
    latestEnvCueType = null;
    envCuePayload = null;
    localBrainHint = null;
    localBrainEmotion = null;
    localBrainIntensity = null;
    sensorData = null;
  }

  Map<String, Object?> snapshot() {
    final m = <String, Object?>{};
    if (currentUserInput != null) m['currentUserInput'] = currentUserInput;
    if (currentEmotion != null) m['currentEmotion'] = currentEmotion.toString();
    if (latestEnvCueType != null) m['latestEnvCueType'] = latestEnvCueType;
    if (envCuePayload != null) m['envCuePayload'] = envCuePayload;
    if (localBrainHint != null) m['localBrainHint'] = localBrainHint;
    if (localBrainEmotion != null) m['localBrainEmotion'] = localBrainEmotion;
    if (localBrainIntensity != null) {
      m['localBrainIntensity'] = localBrainIntensity;
    }
    if (sensorData != null) m['sensorData'] = sensorData;
    return m;
  }

  String toContextBlock({AppLocale? locale}) {
    final parts = <String>[];
    if (currentUserInput != null) {
      parts.add(
        AgentPromptCatalog.text(
          'app.memory.working.user_input',
          locale: locale,
          params: <String, Object?>{'value': currentUserInput},
        ),
      );
    }
    if (currentEmotion != null) {
      parts.add(
        AgentPromptCatalog.text(
          'app.memory.working.emotion',
          locale: locale,
          params: <String, Object?>{'value': currentEmotion},
        ),
      );
    }
    if (latestEnvCueType != null) {
      parts.add(
        AgentPromptCatalog.text(
          envCuePayload == null
              ? 'app.memory.working.env_cue'
              : 'app.memory.working.env_cue_with_payload',
          locale: locale,
          params: <String, Object?>{
            'value': latestEnvCueType,
            'payload': envCuePayload,
          },
        ),
      );
    }
    if (localBrainHint != null) {
      parts.add(
        AgentPromptCatalog.text(
          'app.memory.working.local_brain',
          locale: locale,
          params: <String, Object?>{'value': localBrainHint},
        ),
      );
    }
    if (localBrainEmotion != null) {
      parts.add(
        AgentPromptCatalog.text(
          'app.memory.working.preemit',
          locale: locale,
          params: <String, Object?>{
            'emotion': localBrainEmotion,
            'intensity': localBrainIntensity ?? 0.5,
          },
        ),
      );
    }
    if (sensorData != null && sensorData!.isNotEmpty) {
      parts.add(
        AgentPromptCatalog.text(
          'app.memory.working.sensor_data',
          locale: locale,
          params: <String, Object?>{'value': sensorData},
        ),
      );
    }
    if (parts.isEmpty) return '';
    return '${AgentPromptCatalog.text('app.memory.working.header', locale: locale)}\n'
        '${parts.join('\n')}';
  }
}
