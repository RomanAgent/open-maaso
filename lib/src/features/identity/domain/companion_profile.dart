import 'dart:convert';
import 'dart:typed_data';

/// Only explicit setup choices cross devices. Conversation-derived profile,
/// Soul notes, memories, credentials and local paths are never part of this DTO.
final class CompanionProfile {
  CompanionProfile({
    this.version = 0,
    this.avatarPreset = '',
    this.avatarJpeg = '',
    this.agentGender = '',
    List<String> interests = const [],
    this.onboardingVersion = 0,
  }) : interests = List.unmodifiable(interests) {
    if (version < 0 ||
        version > 9007199254740991 ||
        onboardingVersion < 0 ||
        onboardingVersion > 1 ||
        (avatarPreset.isNotEmpty && !avatarPresets.contains(avatarPreset)) ||
        (agentGender.isNotEmpty && !genders.contains(agentGender)) ||
        interests.length > interestIds.length ||
        interests.toSet().length != interests.length ||
        !interests.every(interestIds.contains) ||
        (avatarPreset.isNotEmpty && avatarJpeg.isNotEmpty)) {
      throw const FormatException('invalid_companion_profile');
    }
    if (avatarJpeg.isNotEmpty) {
      if (avatarJpeg.length > maxAvatarBytes * 4 ~/ 3 + 4) {
        throw const FormatException('avatar_too_large');
      }
      final bytes = base64Decode(avatarJpeg);
      if (bytes.length > maxAvatarBytes ||
          bytes.length < 4 ||
          bytes[0] != 0xff ||
          bytes[1] != 0xd8 ||
          bytes[bytes.length - 2] != 0xff ||
          bytes.last != 0xd9 ||
          base64Encode(bytes) != avatarJpeg) {
        throw const FormatException('invalid_avatar_jpeg');
      }
      _avatarBytes = bytes.asUnmodifiableView();
    } else {
      _avatarBytes = null;
    }
    if (onboardingVersion > 0 &&
        (agentGender.isEmpty || (avatarPreset.isEmpty && avatarJpeg.isEmpty))) {
      throw const FormatException('incomplete_companion_profile');
    }
  }

  static const maxAvatarBytes = 128 * 1024;
  static const avatarPresets = [
    'orbit',
    'star',
    'moon',
    'leaf',
    'wave',
    'spark',
  ];
  static const genders = ['female', 'male', 'nonbinary'];
  static const interestIds = [
    'music',
    'gaming',
    'travel',
    'fitness',
    'books',
    'art',
    'technology',
    'food',
    'nature',
    'movies',
  ];

  final int version;
  final String avatarPreset;
  final String avatarJpeg;
  final String agentGender;
  final List<String> interests;
  final int onboardingVersion;
  // MemoryImage keys use byte identity. Reuse the validated photo across
  // rebuilds without allowing a caller to mutate the shared image data.
  late final Uint8List? _avatarBytes;
  bool get completed => version > 0 && onboardingVersion == 1;
  Uint8List? get avatarBytes => _avatarBytes;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'version': version,
    'avatarPreset': avatarPreset,
    'avatarJpeg': avatarJpeg,
    'agentGender': agentGender,
    'interests': interests,
    'onboardingVersion': onboardingVersion,
  };

  CompanionProfile copyWith({
    int? version,
    String? avatarPreset,
    String? avatarJpeg,
    String? agentGender,
    List<String>? interests,
    int? onboardingVersion,
  }) => CompanionProfile(
    version: version ?? this.version,
    avatarPreset: avatarPreset ?? this.avatarPreset,
    avatarJpeg: avatarJpeg ?? this.avatarJpeg,
    agentGender: agentGender ?? this.agentGender,
    interests: interests ?? this.interests,
    onboardingVersion: onboardingVersion ?? this.onboardingVersion,
  );

  factory CompanionProfile.fromJson(Object? raw) {
    const keys = {
      'schemaVersion',
      'version',
      'avatarPreset',
      'avatarJpeg',
      'agentGender',
      'interests',
      'onboardingVersion',
    };
    if (raw is! Map ||
        raw.length != keys.length ||
        !raw.keys.every(keys.contains) ||
        raw['schemaVersion'] != 1 ||
        raw['version'] is! int ||
        raw['onboardingVersion'] is! int ||
        raw['avatarPreset'] is! String ||
        raw['avatarJpeg'] is! String ||
        raw['agentGender'] is! String ||
        raw['interests'] is! List ||
        !(raw['interests'] as List).every((value) => value is String)) {
      throw const FormatException('invalid_companion_profile');
    }
    return CompanionProfile(
      version: raw['version'] as int,
      avatarPreset: raw['avatarPreset'] as String,
      avatarJpeg: raw['avatarJpeg'] as String,
      agentGender: raw['agentGender'] as String,
      interests: (raw['interests'] as List).cast<String>(),
      onboardingVersion: raw['onboardingVersion'] as int,
    );
  }
}

enum CompanionProfileFailure {
  unavailable,
  authenticationRequired,
  contextChanged,
  conflict,
  rejected,
  invalidResponse,
}

final class CompanionProfileException implements Exception {
  const CompanionProfileException(this.failure);
  final CompanionProfileFailure failure;
  @override
  String toString() => 'CompanionProfileException(${failure.name})';
}

abstract interface class CompanionProfileGateway {
  String get requestContextKey;
  Future<CompanionProfile> fetch({required String expectedContextKey});
  Future<CompanionProfile> update({
    required String expectedContextKey,
    required CompanionProfile profile,
  });
}
