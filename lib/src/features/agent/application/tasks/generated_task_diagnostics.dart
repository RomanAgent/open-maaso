import 'dart:async';

import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

/// Fixed public categories. Provider bodies, generated source and exception
/// prose never form a category or become a task-card explanation.
enum GeneratedTaskFailureCode {
  modelUnavailable,
  modelTimeout,
  modelOutputTruncated,
  modelStreamInterrupted,
  modelSafetyBlocked,
  structuredOutputUnsupported,
  modelAuthentication,
  modelQuotaExceeded,
  modelRateLimited,
  modelContextLimit,
  modelConsentRequired,
  modelMembershipRequired,
  generationStalled,
  generationProfileUnavailable,
  generationCreditInsufficient,
  generationCapacityExceeded,
  generationRequestUnrecognized,
  generationAuthorizationUnavailable,
  responseInvalid,
  surfaceValidationFailed,
  gameRuntimeTimeout,
  gameRuntimeFailed,
  storageFailed,
  quotaExceeded,
  quotaUnavailable,
  actionUnavailable,
  missingArtifact,
  interrupted,
  taskTimeout,
  referenceUnavailable,
  cleanupFailed;

  static GeneratedTaskFailureCode? fromWireName(String? value) {
    for (final code in values) {
      if (code.name == value) return code;
    }
    return null;
  }

  /// Compatibility for records written before typed diagnostics existed.
  /// Only exact application-owned values are accepted; never infer a category
  /// from arbitrary provider text, URLs, stack traces or substring matches.
  static GeneratedTaskFailureCode? fromLegacyError(String? value) {
    if (value == null) return null;
    if (value.startsWith('generated_task_failure:')) {
      return fromWireName(value.substring('generated_task_failure:'.length));
    }
    return switch (value) {
      'local_process_interrupted' => interrupted,
      'hosted_llm_failure:quota' => modelQuotaExceeded,
      'hosted_llm_failure:authentication' => modelAuthentication,
      'hosted_llm_failure:contextLimit' => modelContextLimit,
      'hosted_llm_failure:consent' => modelConsentRequired,
      'hosted_llm_failure:membership' => modelMembershipRequired,
      'hosted_llm_failure:rateLimited' => modelRateLimited,
      'hosted_llm_failure:unavailable' => modelUnavailable,
      'surface_persistence_required' => storageFailed,
      'task_persistence_failed' => storageFailed,
      'project_reference_local_media_missing' ||
      'project_reference_media_unavailable' ||
      'project_reference_scope_mismatch' => referenceUnavailable,
      'surface_worker_first_frame_timeout' => gameRuntimeTimeout,
      'surface_worker_first_frame_unavailable' ||
      'surface_worker_first_frame_gateClosed' => gameRuntimeFailed,
      _ => null,
    };
  }
}

class GeneratedTaskFailure implements Exception {
  const GeneratedTaskFailure(this.code);

  final GeneratedTaskFailureCode code;

  @override
  String toString() => 'generated_task_failure:${code.name}';
}

/// Execution-boundary events, never hidden reasoning or model-authored claims.
enum GeneratedTaskCheckpoint {
  artifactRepair,
  sourcePlanning,
  sourceFileGeneration,
  sourceFileComplete,
  sourceContinuation,
  sourceInspection,
  sourceStalled,
  sourceCapacityExceeded,
  modelRetrying,
  responseReceived,
  modelSummary,
  protocolRepair,
  contentRepair,
  runtimeValidation,
  runtimeRepair,
  waitingForPreview,
  previewAccepted,
}

typedef GeneratedTaskCheckpointObserver =
    void Function(GeneratedTaskCheckpoint checkpoint, {String? publicSummary});

/// `reply` is already a user-facing field of the action contract. Keep its
/// advisory task copy bounded and free of control characters. No provider
/// reasoning fields, source objects or tool payloads enter this function.
String generatedTaskPublicSummary(String value) {
  return String.fromCharCodes(
    value.runes
        .where(
          (rune) =>
              rune >= 32 &&
              !(rune >= 127 && rune <= 159) &&
              !(rune >= 0xD800 && rune <= 0xDFFF) &&
              !(rune >= 0x202A && rune <= 0x202E) &&
              !(rune >= 0x2066 && rune <= 0x2069),
        )
        .take(240),
  ).trim();
}

/// Converts host-authored validator facts to fixed explanations. The original
/// diagnostic may contain generated field names, so it is never copied into
/// task UI or a persisted public progress entry.
String generatedTaskValidationPublicHint(
  String diagnostic, {
  required bool zh,
}) {
  const historicalWebHint = (
    '这是旧版网页代码检查记录；无需因这条记录改写代码或删减内容，应以当前实际运行结果为准。',
    'This is a retired Web code check; do not rewrite code or remove content because of this record. Use the current runtime result.',
  );
  const historicalWebIssues = {
    'public webApps must not use network, storage, dynamic code, navigation, or cross-frame APIs',
    'public webApps must contain playable HTML and JavaScript',
    'public webApps must use only safe HTML elements',
    'public webApps must use only self-contained CSS',
  };
  const hints = <String, (String, String)>{
    'public Applets must not use network or cross-frame APIs': (
      '生成代码调用了网络或跨窗口接口，需要改用作品支持的离线接口。',
      'Generated code uses network or cross-frame APIs that the offline runtime does not support.',
    ),
    'webApp must contain authored HTML or JavaScript': (
      '尚未收到作品的页面或入口代码，需要继续编写作品。',
      'The project has no HTML or JavaScript entry yet and needs to continue being written.',
    ),
    'public Applets must be self-contained': (
      '作品依赖外部资源，需要把可离线使用的内容完整放入作品。',
      'The candidate depends on external resources and must become self-contained for offline use.',
    ),
    'surface source must not reference remote URLs': (
      '作品引用了外部资源地址，当前离线作品不支持这种依赖。',
      'The candidate references remote resources that this offline Surface does not support.',
    ),
    'workerCanvas js must call Game.define with init, update, draw, and input': (
      '游戏脚本缺少运行环境要求的初始化、更新、绘制或输入接口。',
      'The game script is missing required initialization, update, drawing or input interfaces.',
    ),
    'workerCanvas js must use only the declarative Game API': (
      '游戏脚本使用了当前绘制环境不支持的接口。',
      'The game script uses APIs unsupported by the declarative drawing runtime.',
    ),
    'game surfaces must use webApp or workerCanvas rendering': (
      '生成结果选择了不支持游戏的展示方式，需要使用游戏运行环境。',
      'The candidate selected a renderer that does not support games.',
    ),
    'surface.experienceType must be game': (
      '生成结果的类型与小游戏请求不一致，需要修复为游戏作品。',
      'The generated experience type does not match the requested game.',
    ),
    'public Applet source is too large': (
      '作品代码超出了当前单个作品的大小限制。',
      'The candidate exceeds the source size limit for one project.',
    ),
  };
  final public = diagnostic
      .split('; ')
      .map(
        (issue) =>
            historicalWebIssues.contains(issue.trim()) ||
                SurfaceProjectValidator.javaScriptRestrictionFact(issue) !=
                    null ||
                SurfaceProjectValidator.javaScriptLexicalFailureOffset(issue) !=
                    null
            ? historicalWebHint
            : hints[issue.trim()],
      )
      .whereType<(String, String)>()
      .map((hint) => zh ? hint.$1 : hint.$2)
      .toSet();
  if (public.isEmpty) {
    return zh
        ? '生成数据未通过作品契约检查，正在尝试修复。'
        : 'The candidate did not pass the project contract checks; a repair is being attempted.';
  }
  return generatedTaskPublicSummary(public.take(2).join(' '));
}

/// Limits active production time. An explicit user preview/save decision is
/// not production work and must not consume the budget. A budget expiry fences
/// later effects; it does not race or replay an in-flight persistence write.
class GeneratedTaskBudget {
  GeneratedTaskBudget(this.limit, {void Function()? onExpired})
    : _unlimited = false,
      _onExpired = onExpired {
    if (limit <= Duration.zero) throw ArgumentError('invalid_task_budget');
    _clock.start();
    _armExpiry();
  }

  /// Generation has no fixed total-duration cutoff. The transport still owns
  /// idle timeout and cancellation; explicit bounded test/operator runs remain
  /// available through the ordinary constructor.
  GeneratedTaskBudget.unlimited()
    : limit = Duration.zero,
      _unlimited = true,
      _onExpired = null {
    _clock.start();
  }

  final Duration limit;
  final bool _unlimited;
  final Stopwatch _clock = Stopwatch();
  bool _paused = false;
  final void Function()? _onExpired;
  Timer? _expiry;
  bool _closed = false;

  void _armExpiry() {
    _expiry?.cancel();
    if (_unlimited || _closed || _paused || _onExpired == null) return;
    _expiry = Timer(remaining, () {
      if (!_closed && !_paused) _onExpired();
    });
  }

  bool get isExpired => !_unlimited && !_paused && _clock.elapsed >= limit;
  bool get hasDeadline => !_unlimited;
  Duration get remaining {
    if (_unlimited) throw StateError('unbounded_generation_budget');
    final available = limit - _clock.elapsed;
    return available > Duration.zero ? available : Duration.zero;
  }

  void pauseForUser() {
    requireRemaining();
    _paused = true;
    _clock.stop();
    _expiry?.cancel();
  }

  void resume() {
    _paused = false;
    _clock.start();
    _armExpiry();
  }

  void close() {
    _closed = true;
    _expiry?.cancel();
    _clock.stop();
  }

  void requireRemaining() {
    if (isExpired) {
      throw const GeneratedTaskFailure(GeneratedTaskFailureCode.taskTimeout);
    }
  }

  Duration requestTimeout(Duration providerTimeout) {
    requireRemaining();
    if (_unlimited) return providerTimeout;
    return remaining < providerTimeout ? remaining : providerTimeout;
  }

  Future<T> modelRequest<T>(
    Future<T> Function(Duration timeout) request,
    Duration providerTimeout,
  ) async {
    final timeout = requestTimeout(providerTimeout);
    try {
      final result = await request(timeout).timeout(timeout);
      requireRemaining();
      return result;
    } on TimeoutException {
      throw GeneratedTaskFailure(
        isExpired
            ? GeneratedTaskFailureCode.taskTimeout
            : GeneratedTaskFailureCode.modelTimeout,
      );
    }
  }
}
