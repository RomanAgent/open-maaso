import 'dart:convert';

/// User-owned prompt preferences. This is data, never executable skill code.
class OfflineSkill {
  const OfflineSkill({
    required this.id,
    required this.name,
    required this.instructions,
    this.enabled = true,
  });

  static const maxCount = 100;
  static const maxNameLength = 80;
  static const maxInstructionLength = 8192;
  static final _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$');
  static final _unsupportedControls = RegExp(
    r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]',
  );

  final String id;
  final String name;
  final String instructions;
  final bool enabled;

  static const defaults = <OfflineSkill>[
    OfflineSkill(
      id: 'local-clear-answers',
      name: '清晰表达',
      instructions: '先回答核心问题，再补充必要步骤。使用清楚、简短的中文；信息不足时直接说明，不编造结果。',
    ),
    OfflineSkill(
      id: 'local-game-design',
      name: '小游戏设计',
      instructions: '制作小游戏时，给出明确操作、得分反馈和重新开始入口。适配手机触屏，将所需脚本、样式和素材放在作品内，方便离线游玩。',
    ),
    OfflineSkill(
      id: 'local-practical-tools',
      name: '实用小程序',
      instructions:
          '制作工具类小程序时，优先解决一个具体问题。表单有清楚的标签、可读的错误提示和本地状态，避免需要外部服务才能使用的功能。',
    ),
  ];

  factory OfflineSkill.fromJson(Map<String, dynamic> json) {
    if (json.length != 4 ||
        !json.keys.every(
          const {'id', 'name', 'instructions', 'enabled'}.contains,
        )) {
      throw const FormatException('Invalid local skill fields.');
    }
    final id = json['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('Invalid local skill identifier.');
    }
    final name = _text(json['name'], maxNameLength);
    final instructions = _text(json['instructions'], maxInstructionLength);
    final enabled = json['enabled'];
    if (enabled is! bool) {
      throw const FormatException('Invalid local skill state.');
    }
    return OfflineSkill(
      id: id,
      name: name,
      instructions: instructions,
      enabled: enabled,
    );
  }

  static String _text(Object? value, int maximum) {
    if (value is! String ||
        value.length > maximum ||
        value.trim().isEmpty ||
        _unsupportedControls.hasMatch(value)) {
      throw const FormatException('Invalid local skill text.');
    }
    return value.trim();
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'instructions': instructions,
    'enabled': enabled,
  };

  OfflineSkill copyWith({String? name, String? instructions, bool? enabled}) =>
      OfflineSkill.fromJson({
        'id': id,
        'name': name ?? this.name,
        'instructions': instructions ?? this.instructions,
        'enabled': enabled ?? this.enabled,
      });
}

/// A bounded structured preference block, appended after immutable runtime
/// rules. It grants no tools, native authority, network access or permissions.
String buildOfflineSkillContext(Iterable<OfflineSkill> skills) {
  final selected = <Map<String, Object>>[];
  final ids = <String>{};
  var count = 0;
  for (final raw in skills) {
    if (++count > OfflineSkill.maxCount) {
      throw const FormatException('Too many local skills.');
    }
    final skill = OfflineSkill.fromJson(raw.toJson());
    if (!ids.add(skill.id)) {
      throw const FormatException('Duplicate local skill identifier.');
    }
    if (skill.enabled) {
      selected.add({'name': skill.name, 'instructions': skill.instructions});
    }
  }
  if (selected.isEmpty) return '';
  return jsonEncode({
    'kind': 'local_user_prompt_preferences',
    'skills': selected,
  });
}
