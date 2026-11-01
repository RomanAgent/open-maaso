import 'conversation_policy.dart';

enum ConversationHumorStyle { subdued, playful, lightBanter }

const maxConversationPreferenceRevision = 0x1fffffffffffff;

/// Explicit owner-selected persona memory, never relationship evidence or
/// an inferred conversation fact. The owner can change these remembered choices.
final class ConversationPreferenceSnapshot {
  ConversationPreferenceSnapshot({
    required this.accountScopeDigest,
    this.revision = 0,
    this.humorStyle = ConversationHumorStyle.playful,
    this.humorStyleExplicit = false,
    String? preferredAddress,
    Iterable<String> forbiddenAddresses = const [],
    Map<String, BanterDisposition> banterBoundaries = const {},
  }) : preferredAddress =
           preferredAddress == null || preferredAddress.trim().isEmpty
           ? null
           : _address(preferredAddress),
       forbiddenAddresses = List.unmodifiable(
         forbiddenAddresses.map(_address).toSet(),
       ),
       banterBoundaries = Map.unmodifiable(banterBoundaries) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(accountScopeDigest) ||
        revision < 0 ||
        revision > maxConversationPreferenceRevision ||
        this.forbiddenAddresses.length > 16 ||
        this.forbiddenAddresses.contains(this.preferredAddress) ||
        banterBoundaries.length > conversationBanterTopics.length) {
      throw const FormatException('invalid conversation preferences');
    }
    for (final entry in banterBoundaries.entries) {
      if (!conversationBanterTopics.contains(entry.key) ||
          (entry.value == BanterDisposition.accepted &&
              (humorStyle != ConversationHumorStyle.lightBanter ||
                  !conversationLightBanterTopics.contains(entry.key)))) {
        throw const FormatException('invalid conversation topic permission');
      }
    }
  }

  final String accountScopeDigest;
  final int revision;
  final ConversationHumorStyle humorStyle;
  final bool humorStyleExplicit;
  final String? preferredAddress;
  final List<String> forbiddenAddresses;
  final Map<String, BanterDisposition> banterBoundaries;
  bool get noTeasing =>
      humorStyle == ConversationHumorStyle.subdued ||
      banterBoundaries['general'] == BanterDisposition.forbidden;

  Map<String, Object?> toStorageJson() => {
    'schemaVersion': 1,
    'accountScopeDigest': accountScopeDigest,
    'revision': revision,
    'humorStyle': humorStyle.name,
    'humorStyleExplicit': humorStyleExplicit,
    'preferredAddress': preferredAddress,
    'forbiddenAddresses': forbiddenAddresses,
    'banterBoundaries': {
      for (final entry in banterBoundaries.entries) entry.key: entry.value.name,
    },
  };

  factory ConversationPreferenceSnapshot.fromStorageJson(Object? source) {
    const fields = {
      'schemaVersion',
      'accountScopeDigest',
      'revision',
      'humorStyle',
      'humorStyleExplicit',
      'preferredAddress',
      'forbiddenAddresses',
      'banterBoundaries',
    };
    if (source is! Map ||
        source.length != fields.length ||
        source.keys.any((key) => !fields.contains(key)) ||
        source['schemaVersion'] != 1 ||
        source['accountScopeDigest'] is! String ||
        source['revision'] is! int ||
        source['humorStyleExplicit'] is! bool ||
        (source['preferredAddress'] != null &&
            source['preferredAddress'] is! String) ||
        source['forbiddenAddresses'] is! List ||
        source['banterBoundaries'] is! Map) {
      throw const FormatException('invalid conversation preference schema');
    }
    try {
      return ConversationPreferenceSnapshot(
        accountScopeDigest: source['accountScopeDigest'] as String,
        revision: source['revision'] as int,
        humorStyle: ConversationHumorStyle.values.byName(
          source['humorStyle'] as String,
        ),
        humorStyleExplicit: source['humorStyleExplicit'] as bool,
        preferredAddress: source['preferredAddress'] as String?,
        forbiddenAddresses: (source['forbiddenAddresses'] as List)
            .cast<String>(),
        banterBoundaries: {
          for (final entry in (source['banterBoundaries'] as Map).entries)
            entry.key as String: BanterDisposition.values.byName(
              entry.value as String,
            ),
        },
      );
    } on Object {
      throw const FormatException('invalid conversation preference values');
    }
  }

  static String _address(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.runes.length > 32 ||
        !RegExp(
          r'^[\u4e00-\u9fffA-Za-z][\u4e00-\u9fffA-Za-z0-9 _-]*$',
        ).hasMatch(normalized) ||
        RegExp(
          r'(?:不是|不要|别叫|不能|不可以|的时候|的话|的人|只是|而是|会怎样|会怎么样|怎么|如何|为什么|是否|让我|让你|告诉|他说|她说|朋友说|[吗么]$|\b(?:not|don\x27t|never|said|says|should|would|could|means|instead)\b)',
          caseSensitive: false,
        ).hasMatch(normalized)) {
      throw const FormatException('invalid conversation address');
    }
    return normalized;
  }

  /// Matches the prompt snapshot's address grammar. Settings reject unsupported
  /// values instead of reporting a save that the runtime would silently drop.
  static bool supportsAddress(String value) {
    try {
      _address(value);
      return true;
    } on FormatException {
      return false;
    }
  }
}
