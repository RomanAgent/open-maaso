import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import '../domain/companion_profile.dart';
import 'companion_profile_service.dart';

/// User-controlled setup only. Avatar selection stays in its existing
/// authoritative selection/CAS lane; setup never writes renderer preferences.
final class CompanionSetupController extends AppController {
  CompanionSetupController({
    required this.service,
    required this.avatars,
    this.catalog,
    this.onlyMissing = true,
  });
  final CompanionProfileService service;
  final AvatarConfigService avatars;
  final AvatarModelStoreGateway? catalog;
  final bool onlyMissing;
  final draft = Rxn<CompanionProfile>();
  final ready = false.obs;
  final busy = false.obs;
  final issue = RxnString();
  final modelIssue = false.obs;
  bool _retired = false;
  bool get active => !_retired && service.isCurrent;
  bool get completed => service.onboardingCompleted;
  bool get canSave =>
      active &&
      ready.value &&
      !busy.value &&
      draft.value != null &&
      draft.value!.agentGender.isNotEmpty &&
      (draft.value!.avatarPreset.isNotEmpty ||
          draft.value!.avatarJpeg.isNotEmpty);

  Future<void> initialize() async {
    if (!active || busy.value) return;
    busy.value = true;
    issue.value = null;
    try {
      await service.restore();
      if (!active) return;
      // Cached completed setup can open offline. A fresh device fetches the
      // account profile before offering any locally generated defaults.
      final current = service.profile.value;
      final profile = current?.completed == true
          ? current!
          : await service.refresh();
      if (!active) return;
      draft.value = profile;
      ready.value = true;
    } catch (_) {
      if (active) issue.value = 'unavailable';
    } finally {
      if (active) busy.value = false;
    }
    if (active && ready.value) await refreshModels();
  }

  Future<void> refreshModels() async {
    if (!active || catalog == null) return;
    modelIssue.value = false;
    try {
      final models = await catalog!.listApprovedModels();
      if (!active) return;
      avatars.replaceReviewedOptions(
        models
            .where((model) => model.isLoadableOnDevice)
            .map((model) => model.toAvatarOption()),
      );
    } catch (_) {
      if (active) modelIssue.value = true;
    }
  }

  void setAvatarPreset(String value) {
    if (!active ||
        busy.value ||
        draft.value == null ||
        !CompanionProfile.avatarPresets.contains(value)) {
      return;
    }
    draft.value = draft.value!.copyWith(avatarPreset: value, avatarJpeg: '');
  }

  Future<void> setAvatarImage(Uint8List bytes) async {
    if (!active || busy.value || draft.value == null) return;
    busy.value = true;
    issue.value = null;
    try {
      final encoded = await compute(normalizeCompanionAvatar, bytes);
      if (!active) return;
      draft.value = draft.value!.copyWith(
        avatarPreset: '',
        avatarJpeg: encoded,
      );
    } catch (_) {
      if (active) issue.value = 'invalid_image';
    } finally {
      if (active) busy.value = false;
    }
  }

  void setGender(String value) {
    if (!active ||
        busy.value ||
        draft.value == null ||
        !CompanionProfile.genders.contains(value)) {
      return;
    }
    draft.value = draft.value!.copyWith(agentGender: value);
  }

  void toggleInterest(String value) {
    if (!active ||
        busy.value ||
        draft.value == null ||
        !CompanionProfile.interestIds.contains(value)) {
      return;
    }
    final values = draft.value!.interests.toSet();
    values.contains(value) ? values.remove(value) : values.add(value);
    draft.value = draft.value!.copyWith(
      interests: CompanionProfile.interestIds.where(values.contains).toList(),
    );
  }

  Future<void> selectModel(String id) async {
    if (!active || busy.value) return;
    busy.value = true;
    issue.value = null;
    try {
      await avatars.select(id);
    } catch (_) {
      if (active) issue.value = 'model_unavailable';
    } finally {
      if (active) busy.value = false;
    }
  }

  Future<bool> save() async {
    if (!canSave) return false;
    if (onlyMissing && completed) return true;
    busy.value = true;
    issue.value = null;
    try {
      final saved = await service.save(
        draft.value!.copyWith(onboardingVersion: 1),
      );
      if (!active) return false;
      draft.value = saved;
      return true;
    } on CompanionProfileException catch (e) {
      if (active) {
        issue.value = e.failure == CompanionProfileFailure.conflict
            ? 'conflict'
            : 'unavailable';
        if (e.failure == CompanionProfileFailure.conflict) {
          // Show the other device's choices for review; never silently retry.
          try {
            final latest = await service.refresh();
            if (active) draft.value = latest;
          } catch (_) {
            if (active) ready.value = false;
          }
        }
      }
      return false;
    } catch (_) {
      if (active) issue.value = 'unavailable';
      return false;
    } finally {
      if (active) busy.value = false;
    }
  }

  @override
  void onClose() {
    _retired = true;
    super.onClose();
  }
}

/// Runs outside the UI isolate. Re-encoding strips source EXIF/location data.
String normalizeCompanionAvatar(Uint8List bytes) {
  if (bytes.length < 16 || bytes.length > 8 * 1024 * 1024) {
    throw const FormatException('avatar_input_too_large');
  }
  final decoder = image.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 24 * 1024 * 1024) {
    throw const FormatException('avatar_dimensions_invalid');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const FormatException('avatar_decode_failed');
  final oriented = image.bakeOrientation(decoded);
  final square = image.copyResizeCropSquare(
    oriented,
    size: 256,
    interpolation: image.Interpolation.average,
  );
  final clean = image.Image(width: 256, height: 256, numChannels: 3);
  image.compositeImage(clean, square);
  final jpeg = image.encodeJpg(clean, quality: 86);
  if (jpeg.length > CompanionProfile.maxAvatarBytes) {
    throw const FormatException('avatar_too_large');
  }
  return base64Encode(jpeg);
}
