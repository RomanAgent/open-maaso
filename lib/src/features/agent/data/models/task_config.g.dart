// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'task_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TaskConfig _$TaskConfigFromJson(Map<String, dynamic> json) => TaskConfig(
  taskId: json['taskId'] as String?,
  timeout: json['timeoutSeconds'] == null
      ? const Duration(seconds: 30)
      : const _DurationSecondsConverter().fromJson(
          (json['timeoutSeconds'] as num).toInt(),
        ),
  maxRetries: (json['maxRetries'] as num?)?.toInt() ?? 3,
  requireNetwork: json['requireNetwork'] as bool? ?? false,
  requireStorage: json['requireStorage'] as bool? ?? false,
  requireBrowser: json['requireBrowser'] as bool? ?? false,
  requireTts: json['requireTts'] as bool? ?? false,
  requireUi: json['requireUi'] as bool? ?? false,
);

Map<String, dynamic> _$TaskConfigToJson(
  TaskConfig instance,
) => <String, dynamic>{
  'taskId': instance.taskId,
  'timeoutSeconds': const _DurationSecondsConverter().toJson(instance.timeout),
  'maxRetries': instance.maxRetries,
  'requireNetwork': instance.requireNetwork,
  'requireStorage': instance.requireStorage,
  'requireBrowser': instance.requireBrowser,
  'requireTts': instance.requireTts,
  'requireUi': instance.requireUi,
};

const _$TaskConfigJsonSchema = {
  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
  'type': 'object',
  'properties': {
    'taskId': {
      'type': 'string',
      'description':
          'Unique identifier for the task (useful for log tracing and assigning isolated VFS workspaces)',
    },
    'timeoutSeconds': {
      r'$ref': r'#/$defs/Duration',
      'description':
          'Maximum timeout duration for sandbox JS execution (prevents infinite loops from freezing the main thread)',
    },
    'maxRetries': {
      'type': 'integer',
      'description':
          'Maximum number of automatic Debug/Rewrite attempts allowed when the Agent encounters execution errors',
      'default': 3,
    },
    'requireNetwork': {
      'type': 'boolean',
      'description':
          'Whether the task is authorized to access the network\n(If false, the native-layer NetworkPlugin should intercept requests or remain un-injected)',
      'default': false,
    },
    'requireStorage': {
      'type': 'boolean',
      'description':
          'Whether the task is authorized to read/write the local Virtual File System (VFS)',
      'default': false,
    },
    'requireBrowser': {'type': 'boolean', 'default': false},
    'requireTts': {'type': 'boolean', 'default': false},
    'requireUi': {'type': 'boolean', 'default': false},
  },
  r'$defs': {
    'Duration': {'type': 'object', 'properties': {}},
  },
};
