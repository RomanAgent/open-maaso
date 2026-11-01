import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';

/// The voice presentation explicitly assigned to an avatar model.
///
/// This is model metadata, not a visual classifier. Uploaded models without an
/// explicit assignment remain [unspecified] and keep the current voice.
enum AvatarVoiceGender {
  female,
  male,
  unspecified;

  static AvatarVoiceGender fromValue(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'female' || 'woman' || 'f' => AvatarVoiceGender.female,
      'male' || 'man' || 'm' => AvatarVoiceGender.male,
      _ => AvatarVoiceGender.unspecified,
    };
  }
}

/// Owns the user's avatar-aware TTS preference.
///
/// The selected local speaker id is persisted even when Supertonic is not
/// registered yet, so a later pipeline switch or Settings warm-up starts with
/// the correct voice. Manual selection disables model-following until the user
/// chooses the automatic option again.
class AvatarVoiceService {
  AvatarVoiceService({String storageKeyPrefix = ''})
    : _storageKeyPrefix = storageKeyPrefix.trim();

  static const followAvatarPrefsKey = 'tts.follow_avatar';
  // Kept aligned with SherpaNeuralTts' persisted speaker key so the preference
  // is available before the optional local engine is registered.
  static const voiceSidPrefsKey = 'tts.voice_sid';

  static const int defaultFemaleSid = 0;
  static const int defaultMaleSid = 5;

  /// Seed-TTS 2.0 voices used by Maaso's proxy path.
  static const femaleCloudVoice = 'zh_female_vv_uranus_bigtts';
  static const maleCloudVoice = 'zh_male_dayi_saturn_bigtts';

  final String _storageKeyPrefix;

  String get _followAvatarKey => _scopedKey(followAvatarPrefsKey);
  String get _voiceSidKey => _scopedKey(voiceSidPrefsKey);

  final followsAvatar = true.obs;
  final voiceSid = defaultFemaleSid.obs;
  final voiceGender = AvatarVoiceGender.female.obs;

  AvatarVoiceService init() {
    followsAvatar.value = SpUtils.getBool(_followAvatarKey, defValue: true);
    final persistedSid = SpUtils.getInt(
      _voiceSidKey,
      defValue: defaultFemaleSid,
    );
    voiceSid.value = _isValidSid(persistedSid)
        ? persistedSid
        : defaultFemaleSid;
    voiceGender.value = genderForSid(voiceSid.value);
    return this;
  }

  String? get cloudVoiceId => switch (voiceGender.value) {
    AvatarVoiceGender.female => femaleCloudVoice,
    AvatarVoiceGender.male => maleCloudVoice,
    AvatarVoiceGender.unspecified => null,
  };

  Future<void> applyAvatar({
    required AvatarVoiceGender gender,
    int? preferredSid,
  }) async {
    if (!followsAvatar.value || gender == AvatarVoiceGender.unspecified) return;

    final currentSid = voiceSid.value;
    final nextSid = _matchingSid(preferredSid, gender)
        ? preferredSid!
        : genderForSid(currentSid) == gender
        ? currentSid
        : defaultSidFor(gender);
    await _applySid(nextSid);
  }

  Future<void> selectManualSid(int sid) async {
    if (!_isValidSid(sid)) {
      throw ArgumentError.value(sid, 'sid', 'must be between 0 and 9');
    }
    followsAvatar.value = false;
    await SpUtils.put(_followAvatarKey, false);
    await _applySid(sid);
  }

  Future<void> setFollowsAvatar(
    bool enabled, {
    AvatarVoiceGender selectedGender = AvatarVoiceGender.unspecified,
    int? preferredSid,
  }) async {
    followsAvatar.value = enabled;
    await SpUtils.put(_followAvatarKey, enabled);
    if (enabled) {
      await applyAvatar(gender: selectedGender, preferredSid: preferredSid);
    }
  }

  Future<void> _applySid(int sid) async {
    voiceSid.value = sid;
    voiceGender.value = genderForSid(sid);
    await SpUtils.put(_voiceSidKey, sid);
    if (appServices.isRegistered<SherpaNeuralTts>()) {
      final sherpa = appServices.find<SherpaNeuralTts>();
      if (_storageKeyPrefix.isEmpty) {
        await sherpa.setVoiceSid(sid);
      } else {
        // The Sherpa service still owns a legacy global preference key. A
        // scoped AvatarVoiceService persists above and only updates the live
        // engine projection here, otherwise account A would overwrite that
        // unscoped key while it is mounted.
        sherpa.voiceSid.value = sid;
      }
      return;
    }
  }

  String _scopedKey(String legacyKey) => _storageKeyPrefix.isEmpty
      ? legacyKey
      : '$_storageKeyPrefix.preferences.$legacyKey';

  static int defaultSidFor(AvatarVoiceGender gender) => switch (gender) {
    AvatarVoiceGender.male => defaultMaleSid,
    AvatarVoiceGender.female ||
    AvatarVoiceGender.unspecified => defaultFemaleSid,
  };

  static AvatarVoiceGender genderForSid(int sid) {
    if (sid >= 0 && sid <= 4) return AvatarVoiceGender.female;
    if (sid >= 5 && sid <= 9) return AvatarVoiceGender.male;
    return AvatarVoiceGender.unspecified;
  }

  static bool _matchingSid(int? sid, AvatarVoiceGender gender) =>
      sid != null && _isValidSid(sid) && genderForSid(sid) == gender;

  static bool _isValidSid(int sid) => sid >= 0 && sid <= 9;
}
