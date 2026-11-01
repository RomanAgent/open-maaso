import 'package:maaso/src/features/agent/application/persona/agent_persona_spec.dart';

const Object _agentProfileUnset = Object();

class AgentProfile {
  String userId;
  String nickname;
  String avatar;
  String bio;
  List<String> personalityTraits;
  String catchphrase;
  int wakeUpHour;
  int sleepHour;
  String? longTermMemory;
  String agentToken;
  String gender;
  String voiceId;
  DateTime? birthDate;
  AgentPersonaSpec persona;

  /// Persisted UI style key. Kept for compatibility with older profile rows;
  /// the app now renders a single iOS-style app surface.
  String uiStyle;

  /// Persisted theme brightness — `'light'` or `'dark'`.  Orthogonal to
  /// [uiStyle]; [ThemeService] resolves it alongside the settings selection.
  String themeBrightness;

  /// Persisted theme mode — `'system'`, `'light'`, or `'dark'`.
  /// New profiles follow the system. Legacy rows with a brightness but no mode
  /// keep using [themeBrightness] until the user chooses another mode.
  String? themeMode;

  /// Persisted accent/palette key (see [AppAccent]).  Drives the seed colour
  /// of the active theme resolved by [ThemeService].
  String themeAccent;

  AgentProfile({
    this.userId = 'self',
    required this.nickname,
    required this.avatar,
    required this.bio,
    required this.personalityTraits,
    required this.catchphrase,
    this.wakeUpHour = 8,
    this.sleepHour = 23,
    this.longTermMemory,
    this.agentToken = '',
    this.gender = '',
    this.voiceId = '',
    this.birthDate,
    this.persona = AgentPersonaSpec.empty,
    this.uiStyle = 'adventure_world',
    this.themeBrightness = 'light',
    this.themeMode = 'system',
    this.themeAccent = 'blue',
  });

  Map<String, Object?> toJson() => {
    'userId': userId,
    'nickname': nickname,
    'avatar': avatar,
    'bio': bio,
    'personalityTraits': personalityTraits,
    'catchphrase': catchphrase,
    'wakeUpHour': wakeUpHour,
    'sleepHour': sleepHour,
    if (longTermMemory != null) 'longTermMemory': longTermMemory,
    'agentToken': agentToken,
    'gender': gender,
    'voiceId': voiceId,
    if (birthDate != null) 'birthDate': birthDate!.toIso8601String(),
    if (!persona.isNeutral) 'persona': persona.toJson(),
    'uiStyle': uiStyle,
    'themeBrightness': themeBrightness,
    if (themeMode != null) 'themeMode': themeMode,
    'themeAccent': themeAccent,
  };

  factory AgentProfile.fromJson(Map<String, Object?> json) => AgentProfile(
    userId: json['userId'] as String? ?? 'self',
    nickname: json['nickname'] as String? ?? '',
    avatar: json['avatar'] as String? ?? '',
    bio: json['bio'] as String? ?? '',
    personalityTraits:
        (json['personalityTraits'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[],
    catchphrase: json['catchphrase'] as String? ?? '',
    wakeUpHour: (json['wakeUpHour'] as num?)?.toInt() ?? 8,
    sleepHour: (json['sleepHour'] as num?)?.toInt() ?? 23,
    longTermMemory: json['longTermMemory'] as String?,
    agentToken: json['agentToken'] as String? ?? '',
    gender: json['gender'] as String? ?? '',
    voiceId: json['voiceId'] as String? ?? '',
    birthDate: json['birthDate'] == null
        ? null
        : DateTime.tryParse(json['birthDate'].toString()),
    persona: AgentPersonaSpec.fromJson(json['persona']),
    uiStyle: 'adventure_world',
    themeBrightness: json['themeBrightness'] as String? ?? 'light',
    themeMode:
        json['themeMode'] as String? ??
        (json['themeBrightness'] == 'light' || json['themeBrightness'] == 'dark'
            ? null
            : 'system'),
    themeAccent: json['themeAccent'] as String? ?? 'blue',
  );

  AgentProfile copyWith({
    String? userId,
    String? nickname,
    String? avatar,
    String? bio,
    List<String>? personalityTraits,
    String? catchphrase,
    int? wakeUpHour,
    int? sleepHour,
    Object? longTermMemory = _agentProfileUnset,
    String? agentToken,
    String? gender,
    String? voiceId,
    Object? birthDate = _agentProfileUnset,
    AgentPersonaSpec? persona,
    String? uiStyle,
    String? themeBrightness,
    Object? themeMode = _agentProfileUnset,
    String? themeAccent,
  }) {
    return AgentProfile(
      userId: userId ?? this.userId,
      nickname: nickname ?? this.nickname,
      avatar: avatar ?? this.avatar,
      bio: bio ?? this.bio,
      personalityTraits: List<String>.from(
        personalityTraits ?? this.personalityTraits,
      ),
      catchphrase: catchphrase ?? this.catchphrase,
      wakeUpHour: wakeUpHour ?? this.wakeUpHour,
      sleepHour: sleepHour ?? this.sleepHour,
      longTermMemory: identical(longTermMemory, _agentProfileUnset)
          ? this.longTermMemory
          : longTermMemory as String?,
      agentToken: agentToken ?? this.agentToken,
      gender: gender ?? this.gender,
      voiceId: voiceId ?? this.voiceId,
      birthDate: identical(birthDate, _agentProfileUnset)
          ? this.birthDate
          : birthDate as DateTime?,
      persona: persona ?? this.persona,
      uiStyle: uiStyle ?? this.uiStyle,
      themeBrightness: themeBrightness ?? this.themeBrightness,
      themeMode: identical(themeMode, _agentProfileUnset)
          ? this.themeMode
          : themeMode as String?,
      themeAccent: themeAccent ?? this.themeAccent,
    );
  }
}
