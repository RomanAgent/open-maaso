import 'package:json_annotation/json_annotation.dart';

//dart run build_runner build
// This file will be generated automatically by build_runner
part 'task_config.g.dart';

/// Custom converter to map [Duration] to an integer representing seconds in JSON
class _DurationSecondsConverter implements JsonConverter<Duration, int> {
  const _DurationSecondsConverter();

  @override
  Duration fromJson(int json) => Duration(seconds: json);

  @override
  int toJson(Duration object) => object.inSeconds;
}

/// Task Execution Configuration Model
/// Defines the boundary conditions, resource quotas, and permission restrictions
/// when an Agent executes a single task.
@JsonSerializable(createJsonSchema: true)
class TaskConfig {
  /// Unique identifier for the task (useful for log tracing and assigning isolated VFS workspaces)
  final String taskId;

  /// Maximum timeout duration for sandbox JS execution (prevents infinite loops from freezing the main thread)
  @JsonKey(name: 'timeoutSeconds')
  @_DurationSecondsConverter()
  final Duration timeout;

  /// Maximum number of automatic Debug/Rewrite attempts allowed when the Agent encounters execution errors
  @JsonKey(defaultValue: 3)
  final int maxRetries;

  /// Whether the task is authorized to access the network
  /// (If false, the native-layer NetworkPlugin should intercept requests or remain un-injected)
  @JsonKey(defaultValue: false)
  final bool requireNetwork;

  /// Whether the task is authorized to read/write the local Virtual File System (VFS)
  @JsonKey(defaultValue: false)
  final bool requireStorage;

  @JsonKey(defaultValue: false)
  final bool requireBrowser;

  @JsonKey(defaultValue: false)
  final bool requireTts;

  @JsonKey(defaultValue: false)
  final bool requireUi;

  TaskConfig({
    String? taskId,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.requireNetwork = false,
    this.requireStorage = false,
    this.requireBrowser = false,
    this.requireTts = false,
    this.requireUi = false,
  }) : taskId =
           taskId ?? 'default_task_${DateTime.now().millisecondsSinceEpoch}',
       assert(maxRetries >= 0, 'maxRetries cannot be negative'),
       assert(timeout.inSeconds > 0, 'timeout must be positive');

  /// Creates a copy of this [TaskConfig] but with the given fields replaced with the new values.
  TaskConfig copyWith({
    String? taskId,
    Duration? timeout,
    int? maxRetries,
    bool? requireNetwork,
    bool? requireStorage,
  }) {
    return TaskConfig(
      taskId: taskId ?? this.taskId,
      timeout: timeout ?? this.timeout,
      maxRetries: maxRetries ?? this.maxRetries,
      requireNetwork: requireNetwork ?? this.requireNetwork,
      requireStorage: requireStorage ?? this.requireStorage,
      requireBrowser: requireNetwork ?? requireBrowser,
      requireTts: requireStorage ?? requireTts,
      requireUi: requireNetwork ?? requireUi,
    );
  }

  /// Connect the generated [_$TaskConfigFromJson] function to the `fromJson` factory.
  factory TaskConfig.fromJson(Map<String, dynamic> json) =>
      _$TaskConfigFromJson(json);

  /// Connect the generated [_$TaskConfigToJson] function to the `toJson` method.
  Map<String, dynamic> toJson() => _$TaskConfigToJson(this);

  /// The JSON Schema for this class.
  static const jsonSchema = _$TaskConfigJsonSchema;

  @override
  String toString() {
    return 'TaskConfig(taskId: $taskId, timeout: ${timeout.inSeconds}s, retries: $maxRetries, network: $requireNetwork, storage: $requireStorage)';
  }
}
