import 'dart:math' as math;

import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/local_brain_service.dart';

class IntentWaveService extends AppService {
  static const _components = <String>[
    'chitchat',
    'task',
    'knowledge',
    'emotionalCare',
    'longWorkflow',
    'systemAction',
    'emergency',
  ];

  // 缓存常用值，避免重复计算
  static final _logComponentsLength = math.log(_components.length);

  // 预编译的关键词集合，用于快速匹配
  static const _taskKeywords = <String>{
    '帮我',
    '查',
    '打开',
    '设置',
    '创建',
    '修改',
    '实现',
    'fix',
    'build',
    'create',
    'update',
  };

  static const _longWorkflowKeywords = <String>{
    '计划',
    '方案',
    '架构',
    '设计',
    '梳理',
    'roadmap',
    'plan',
    'architecture',
  };

  static const _emotionalCareKeywords = <String>{
    '难过',
    '累',
    '害怕',
    '烦',
    '开心',
    '陪',
    'sad',
    'tired',
    'happy',
    'angry',
  };

  static const _questionKeywords = <String>{
    '为什么',
    '怎么',
    '如何',
    '是否',
    'what',
    'why',
    'how',
    'can you',
  };

  final Rx<IntentWaveSnapshot> snapshot = IntentWaveSnapshot.initial().obs;

  void observeUserText(String text) {
    final lower = text.trim().toLowerCase();
    if (lower.isEmpty) return;
    final updates = <String, double>{};

    if (_looksQuestion(lower)) updates['knowledge'] = 0.34;
    if (_containsAnyKeyword(lower, _taskKeywords)) {
      updates['task'] = 0.36;
    }
    if (_containsAnyKeyword(lower, _longWorkflowKeywords)) {
      updates['longWorkflow'] = 0.28;
    }
    if (_containsAnyKeyword(lower, _emotionalCareKeywords)) {
      updates['emotionalCare'] = 0.30;
      updates['chitchat'] = 0.16;
    }
    if (updates.isEmpty) updates['chitchat'] = 0.18;

    _apply(
      updates,
      evidence:
          'user_text:${text.length > 28 ? '${text.substring(0, 28)}...' : text}',
    );
  }

  void absorbRoutingDecision(RoutingDecision decision) {
    final updates = <String, double>{
      _componentForIntent(decision.intent): decision.confidence.clamp(0.0, 1.0),
    };
    if (decision.needsTools.isNotEmpty) updates['systemAction'] = 0.36;
    if (decision.intent == LocalIntent.task) updates['longWorkflow'] = 0.12;
    _apply(
      updates,
      evidence:
          'local_route:${decision.intent.name}/${decision.confidence.toStringAsFixed(2)}',
      decay: 0.90,
    );
  }

  IntentWaveGate observeEnvironment(SystemStatusEvent event) {
    final trigger = event.triggerType;
    final updates = <String, double>{};
    var thresholdEvent = false;

    if (trigger.startsWith('user_emotion_')) {
      final label = trigger.substring('user_emotion_'.length);
      updates['emotionalCare'] = switch (label) {
        'sleepy' => 0.48,
        'flat' => 0.38,
        'absent' => 0.34,
        'happy' => 0.26,
        _ => 0.30,
      };
      updates['chitchat'] = 0.14;
      thresholdEvent = label != 'happy';
    } else {
      switch (trigger) {
        case 'battery_critical':
          updates['emergency'] = 0.82;
          updates['systemAction'] = 0.70;
          thresholdEvent = true;
        case 'battery_low':
          updates['systemAction'] = 0.58;
          thresholdEvent = true;
        case 'network_offline':
          updates['systemAction'] = 0.46;
          thresholdEvent = true;
        case 'network_online':
        case 'battery_charging':
        case 'battery_unplugged':
          updates['systemAction'] = 0.28;
        case 'motion_high':
          updates['emergency'] = 0.45;
          updates['systemAction'] = 0.32;
          thresholdEvent = true;
        case 'late_night':
          updates['emotionalCare'] = 0.42;
          updates['chitchat'] = 0.16;
          thresholdEvent = true;
        case 'vision_scene':
          updates['knowledge'] = 0.22;
          updates['emotionalCare'] = 0.16;
        case 'app_resumed':
          updates['chitchat'] = 0.08;
        default:
          updates['systemAction'] = 0.12;
      }
    }

    _apply(updates, evidence: 'env:$trigger');
    final current = snapshot.value;
    final dominant = current.dominantComponent;
    final dominantAmp = current.amplitudes[dominant] ?? 0;
    final shouldCollapse =
        thresholdEvent && (dominantAmp >= 0.32 || current.entropy <= 0.72);
    if (shouldCollapse) {
      collapse(reason: 'environment:$trigger', preferredComponent: dominant);
    }
    return IntentWaveGate(
      shouldCollapse: shouldCollapse,
      component: dominant,
      entropy: current.entropy,
      reason: trigger,
    );
  }

  IntentWaveSnapshot collapse({
    required String reason,
    String? preferredComponent,
  }) {
    final current = snapshot.value;
    final collapsed = preferredComponent ?? current.dominantComponent;
    final next = current.copyWith(
      lastCollapsedComponent: collapsed,
      lastCollapseReason: reason,
      lastCollapsedAt: DateTime.now(),
      collapseCount: current.collapseCount + 1,
    );
    snapshot.value = next;
    return next;
  }

  Map<String, dynamic> toDebugMap() {
    final s = snapshot.value;
    final probabilities = s.probabilities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      'entropy': s.entropy.toStringAsFixed(2),
      'dominant': s.dominantComponent,
      'lastCollapsed': s.lastCollapsedComponent,
      'lastReason': s.lastCollapseReason,
      'collapseCount': s.collapseCount.toString(),
      'rows': [
        for (final entry in probabilities)
          {
            'label': entry.key,
            'value': '${(entry.value * 100).toStringAsFixed(0)}%',
            'detail':
                'amp ${(s.amplitudes[entry.key] ?? 0).toStringAsFixed(2)}',
          },
      ],
      'evidence': s.evidence.reversed.take(5).toList(),
    };
  }

  void _apply(
    Map<String, double> updates, {
    required String evidence,
    double decay = 0.86,
  }) {
    if (updates.isEmpty) return;
    final current = snapshot.value;

    // 复用现有 Map，避免每次都创建新 Map
    final nextAmplitudes = Map<String, double>.from(current.amplitudes);
    for (final key in _components) {
      final old = nextAmplitudes[key] ?? 0;
      final incoming = updates[key] ?? 0;
      nextAmplitudes[key] = math.max(old * decay, incoming).clamp(0.0, 1.0);
    }

    // 优化证据列表处理
    final List<String> nextEvidence;
    if (current.evidence.length >= 16) {
      nextEvidence = current.evidence.sublist(1)..add(evidence);
    } else {
      nextEvidence = [...current.evidence, evidence];
    }

    snapshot.value = current.copyWith(
      amplitudes: nextAmplitudes,
      entropy: _entropy(nextAmplitudes),
      evidence: nextEvidence,
      updatedAt: DateTime.now(),
    );
  }

  static String _componentForIntent(LocalIntent intent) {
    return switch (intent) {
      LocalIntent.chitchat => 'chitchat',
      LocalIntent.task => 'task',
      LocalIntent.knowledge => 'knowledge',
      LocalIntent.emergency => 'emergency',
      LocalIntent.unknown => 'chitchat',
    };
  }

  static double _entropy(Map<String, double> amplitudes) {
    final sum = amplitudes.values.fold<double>(0, (a, b) => a + b);
    if (sum <= 0) return 1;
    var entropy = 0.0;
    for (final amp in amplitudes.values) {
      if (amp <= 0) continue;
      final p = amp / sum;
      entropy -= p * math.log(p);
    }
    return (entropy / _logComponentsLength).clamp(0.0, 1.0);
  }

  static bool _looksQuestion(String lower) {
    return lower.contains('?') ||
        lower.contains('？') ||
        _containsAnyKeyword(lower, _questionKeywords);
  }

  // 优化后的关键词匹配：使用 Set 并尽可能提前返回
  static bool _containsAnyKeyword(String value, Set<String> keywords) {
    for (final keyword in keywords) {
      if (value.contains(keyword)) {
        return true;
      }
    }
    return false;
  }
}

class IntentWaveSnapshot {
  IntentWaveSnapshot({
    required this.amplitudes,
    required this.entropy,
    required this.evidence,
    required this.updatedAt,
    this.lastCollapsedComponent,
    this.lastCollapseReason,
    this.lastCollapsedAt,
    this.collapseCount = 0,
  }) : _probabilities = null,
       _dominantComponent = null;

  factory IntentWaveSnapshot.initial() {
    return IntentWaveSnapshot(
      amplitudes: {
        for (final component in IntentWaveService._components) component: 0.01,
      },
      entropy: 1,
      evidence: const [],
      updatedAt: DateTime.now(),
    );
  }

  final Map<String, double> amplitudes;
  final double entropy;
  final List<String> evidence;
  final DateTime updatedAt;
  final String? lastCollapsedComponent;
  final String? lastCollapseReason;
  final DateTime? lastCollapsedAt;
  final int collapseCount;

  // 缓存计算结果
  Map<String, double>? _probabilities;
  String? _dominantComponent;

  Map<String, double> get probabilities {
    if (_probabilities != null) return _probabilities!;
    final sum = amplitudes.values.fold<double>(0, (a, b) => a + b);
    if (sum <= 0) {
      _probabilities = {for (final key in amplitudes.keys) key: 0};
    } else {
      _probabilities = {
        for (final e in amplitudes.entries) e.key: e.value / sum,
      };
    }
    return _probabilities!;
  }

  String get dominantComponent {
    if (_dominantComponent != null) return _dominantComponent!;
    var best = amplitudes.keys.first;
    var bestValue = amplitudes[best] ?? 0;
    for (final entry in amplitudes.entries) {
      if (entry.value > bestValue) {
        best = entry.key;
        bestValue = entry.value;
      }
    }
    _dominantComponent = best;
    return best;
  }

  IntentWaveSnapshot copyWith({
    Map<String, double>? amplitudes,
    double? entropy,
    List<String>? evidence,
    DateTime? updatedAt,
    String? lastCollapsedComponent,
    String? lastCollapseReason,
    DateTime? lastCollapsedAt,
    int? collapseCount,
  }) {
    return IntentWaveSnapshot(
      amplitudes: amplitudes ?? this.amplitudes,
      entropy: entropy ?? this.entropy,
      evidence: evidence ?? this.evidence,
      updatedAt: updatedAt ?? this.updatedAt,
      lastCollapsedComponent:
          lastCollapsedComponent ?? this.lastCollapsedComponent,
      lastCollapseReason: lastCollapseReason ?? this.lastCollapseReason,
      lastCollapsedAt: lastCollapsedAt ?? this.lastCollapsedAt,
      collapseCount: collapseCount ?? this.collapseCount,
    );
  }
}

class IntentWaveGate {
  const IntentWaveGate({
    required this.shouldCollapse,
    required this.component,
    required this.entropy,
    required this.reason,
  });

  final bool shouldCollapse;
  final String component;
  final double entropy;
  final String reason;
}
