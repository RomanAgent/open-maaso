import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_voice_service.dart';
import 'package:maaso/src/core/services/maaso_proxy_tts_engine.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    appServices.testMode = true;
    appServices.reset();
    SharedPreferences.setMockInitialValues({});
    await SpUtils.init();
  });

  tearDown(appServices.reset);

  test(
    'avatar following maps female and male models to stable SID groups',
    () async {
      final voice = AvatarVoiceService().init();

      await voice.applyAvatar(gender: AvatarVoiceGender.female);
      expect(voice.voiceSid.value, inInclusiveRange(0, 4));
      expect(voice.cloudVoiceId, AvatarVoiceService.femaleCloudVoice);

      await voice.applyAvatar(gender: AvatarVoiceGender.male);
      expect(voice.voiceSid.value, AvatarVoiceService.defaultMaleSid);
      expect(voice.cloudVoiceId, AvatarVoiceService.maleCloudVoice);

      await voice.applyAvatar(gender: AvatarVoiceGender.male, preferredSid: 8);
      expect(voice.voiceSid.value, 8);
    },
  );

  test(
    'manual voice survives model changes until automatic mode is restored',
    () async {
      final voice = AvatarVoiceService().init();

      await voice.selectManualSid(8);
      await voice.applyAvatar(gender: AvatarVoiceGender.female);

      expect(voice.followsAvatar.value, isFalse);
      expect(voice.voiceSid.value, 8);

      await voice.setFollowsAvatar(
        true,
        selectedGender: AvatarVoiceGender.female,
      );

      expect(voice.followsAvatar.value, isTrue);
      expect(voice.voiceSid.value, AvatarVoiceService.defaultFemaleSid);
      expect(SpUtils.getBool(AvatarVoiceService.followAvatarPrefsKey), isTrue);
      expect(
        SpUtils.getInt(AvatarVoiceService.voiceSidPrefsKey),
        AvatarVoiceService.defaultFemaleSid,
      );
    },
  );

  test('failed avatar load does not change the current voice', () async {
    final active = appServices.put(ActiveAvatarRuntime());
    final runtime = _FakeAvatarRuntime()..failingModelUrl = 'model://male';
    active.register(runtime);
    final voice = AvatarVoiceService().init();
    final avatars = AvatarConfigService(
      voicePreferences: voice,
      initialCatalog: const [
        AvatarOption(
          id: 'female',
          name: 'Female',
          backend: AvatarBackendKind.unity,
          modelUrl: 'model://female',
          voiceGender: AvatarVoiceGender.female,
          isDefault: true,
        ),
        AvatarOption(
          id: 'male',
          name: 'Male',
          backend: AvatarBackendKind.unity,
          modelUrl: 'model://male',
          voiceGender: AvatarVoiceGender.male,
        ),
      ],
    ).init();
    await Future<void>.delayed(Duration.zero);

    await expectLater(avatars.select('male'), throwsStateError);

    expect(avatars.selected.id, 'female');
    expect(voice.voiceGender.value, AvatarVoiceGender.female);
    expect(voice.voiceSid.value, AvatarVoiceService.defaultFemaleSid);
  });

  test('successful avatar switch commits the matching voice', () async {
    final active = appServices.put(ActiveAvatarRuntime());
    active.register(_FakeAvatarRuntime());
    final voice = AvatarVoiceService().init();
    final avatars = AvatarConfigService(
      voicePreferences: voice,
      initialCatalog: const [
        AvatarOption(
          id: 'female',
          name: 'Female',
          backend: AvatarBackendKind.unity,
          modelUrl: 'model://female',
          voiceGender: AvatarVoiceGender.female,
          isDefault: true,
        ),
        AvatarOption(
          id: 'male',
          name: 'Male',
          backend: AvatarBackendKind.unity,
          modelUrl: 'model://male',
          voiceGender: AvatarVoiceGender.male,
        ),
      ],
    ).init();

    await avatars.select('male');

    expect(avatars.selectedId.value, 'male');
    expect(voice.voiceGender.value, AvatarVoiceGender.male);
    expect(voice.voiceSid.value, AvatarVoiceService.defaultMaleSid);
  });

  test(
    'reviewed descriptors use explicit metadata and known official keys',
    () {
      final explicit = ApprovedAvatarModel.fromJson({
        'id': 31,
        'modelKey': 'community.lumen.v1',
        'displayName': 'Lumen',
        'modelSource': 'community',
        'voiceGender': 'female',
        'voiceProfile': {'localSid': 3},
        'assetUrl': 'https://cdn.example.com/lumen.bundle',
        'assetSha256': 'a' * 64,
        'runtimeConfig': {'assetName': 'Lumen'},
        'compatibility': {
          'backends': ['unity'],
        },
      });
      final officialMale = ApprovedAvatarModel.fromJson({
        'id': 32,
        'modelKey': 'masso.official.modular-male',
        'displayName': 'Modular Male',
        'modelSource': 'official',
        'assetUrl': 'https://cdn.example.com/male.bundle',
        'assetSha256': 'b' * 64,
        'runtimeConfig': {'assetName': 'Male'},
        'compatibility': {
          'backends': ['unity'],
        },
      });
      final unclassified = ApprovedAvatarModel.fromJson({
        'id': 33,
        'modelKey': 'community.unknown.v1',
        'displayName': 'Female-looking upload',
        'modelSource': 'community',
        'assetUrl': 'https://cdn.example.com/unknown.bundle',
        'assetSha256': 'c' * 64,
        'runtimeConfig': {'assetName': 'Unknown'},
        'compatibility': {
          'backends': ['unity'],
        },
      });

      expect(explicit.toAvatarOption().voiceGender, AvatarVoiceGender.female);
      expect(explicit.toAvatarOption().preferredVoiceSid, 3);
      expect(officialMale.toAvatarOption().voiceGender, AvatarVoiceGender.male);
      expect(
        unclassified.toAvatarOption().voiceGender,
        AvatarVoiceGender.unspecified,
      );
    },
  );

  test(
    'proxy TTS receives avatar cloud voice while other engines stay unchanged',
    () async {
      final voice = AvatarVoiceService().init();
      await voice.applyAvatar(gender: AvatarVoiceGender.male);
      final proxy = MaasoProxyTtsEngine(
        baseUri: Uri.parse('https://api.example.com'),
        accessTokenProvider: () async => 'token',
      );

      expect(
        resolveAvatarAwareTtsVoice(
          engine: proxy,
          avatarVoice: voice,
          configuredVoice: 'legacy',
        ),
        AvatarVoiceService.maleCloudVoice,
      );
      expect(
        resolveAvatarAwareTtsVoice(
          engine: _FakeTtsEngine(),
          avatarVoice: voice,
          configuredVoice: 'legacy',
        ),
        'legacy',
      );

      proxy.close();
    },
  );
}

class _FakeTtsEngine implements TTSEngine {
  @override
  bool get isReady => true;

  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) async => Uint8List(0);

  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) async => true;
}

class _FakeAvatarRuntime extends AvatarRuntime {
  String? failingModelUrl;

  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;

  @override
  final isReady = true.obs;

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {
    if (modelUrl == failingModelUrl) throw StateError('load failed');
  }

  @override
  Future<void> clearGaze() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async {}

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async {}

  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) async {}

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async {}

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {}

  @override
  Future<void> setFraming(String mode) async {}

  @override
  Future<void> setGaze(AvatarGaze gaze) async {}

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async {}

  @override
  Future<void> setMouthOpen(double value) async {}

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}

  @override
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async {}

  @override
  Future<void> stopLipSync() async {}
}
