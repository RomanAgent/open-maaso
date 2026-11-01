import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import '../domain/companion_profile.dart';
import '../domain/identity_profile.dart';
import 'companion_profile_service.dart';
import 'companion_setup_controller.dart';
import 'identity_service.dart';

enum ProfileEditField { nickname, avatar, interests }

/// The visible personal form owns drafts only. Each human save updates one
/// account field through its existing service; Agent actions cannot save.
final class ProfileController extends AppController {
  ProfileController({required this.identity, required this.companion});
  final IdentityService identity;
  final CompanionProfileService companion;
  final loading = false.obs;
  final busy = false.obs;
  final issue = RxnString();
  final editing = Rxn<ProfileEditField>();
  final nickname = ''.obs;
  final draft = Rxn<CompanionProfile>();
  bool _retired = false;
  bool _userControl = false;
  int? _identityVersion;

  bool get active {
    // Subscribe visible drafts to account retirement even when their current
    // editor does not otherwise read the shared profile projections.
    companion.profile.value;
    identity.profile;
    return !_retired &&
        identity.isCurrent &&
        companion.isCurrent &&
        identity.boundContextKey == companion.boundContextKey;
  }

  bool get canEdit =>
      active &&
      !loading.value &&
      !busy.value &&
      identity.profile?.completed == true &&
      companion.profile.value != null;

  @override
  Future<void> refresh() async {
    if (!active || loading.value || busy.value || editing.value != null) return;
    loading.value = true;
    issue.value = null;
    try {
      await Future.wait([identity.load(), companion.refresh()]);
    } catch (_) {
      if (active) issue.value = 'unavailable';
    } finally {
      if (active) loading.value = false;
    }
  }

  void setUserControl(bool value) => _userControl = value;

  bool beginEdit(ProfileEditField field) {
    if (!canEdit || editing.value != null) return false;
    _identityVersion = identity.profile!.version;
    nickname.value = identity.profile!.playerName;
    draft.value = companion.profile.value;
    issue.value = null;
    editing.value = field;
    return true;
  }

  bool prepareNickname(String value) {
    if (_userControl || IdentityNames.validate(value) != null) return false;
    if (!beginEdit(ProfileEditField.nickname)) return false;
    nickname.value = value.trim();
    return true;
  }

  bool prepareInterests(List<String> values) {
    if (_userControl ||
        values.length > CompanionProfile.interestIds.length ||
        values.toSet().length != values.length ||
        !values.every(CompanionProfile.interestIds.contains)) {
      return false;
    }
    if (!beginEdit(ProfileEditField.interests)) return false;
    draft.value = draft.value!.copyWith(interests: values);
    return true;
  }

  void updateNickname(String value) {
    if (!active || busy.value || editing.value != ProfileEditField.nickname) {
      return;
    }
    nickname.value = value;
  }

  void setAvatarPreset(String preset) {
    if (!active ||
        busy.value ||
        editing.value != ProfileEditField.avatar ||
        !CompanionProfile.avatarPresets.contains(preset)) {
      return;
    }
    draft.value = draft.value!.copyWith(avatarPreset: preset, avatarJpeg: '');
  }

  Future<void> setAvatarImage(Uint8List bytes) async {
    if (!active || busy.value || editing.value != ProfileEditField.avatar) {
      return;
    }
    busy.value = true;
    issue.value = null;
    try {
      final encoded = await compute(normalizeCompanionAvatar, bytes);
      if (!active || editing.value != ProfileEditField.avatar) return;
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

  void toggleInterest(String value) {
    if (!active ||
        busy.value ||
        editing.value != ProfileEditField.interests ||
        !CompanionProfile.interestIds.contains(value)) {
      return;
    }
    final selected = draft.value!.interests.toSet();
    selected.contains(value) ? selected.remove(value) : selected.add(value);
    draft.value = draft.value!.copyWith(
      interests: CompanionProfile.interestIds.where(selected.contains).toList(),
    );
  }

  void cancelEdit() {
    if (busy.value) return;
    editing.value = null;
    draft.value = null;
    nickname.value = '';
    _identityVersion = null;
    issue.value = null;
  }

  /// Called only by the visible save button. A stale CAS draft is retained for
  /// review, never silently merged over a newer device's explicit choices.
  Future<bool> save() async {
    if (!active || busy.value || editing.value == null) return false;
    if (editing.value == ProfileEditField.nickname &&
        IdentityNames.validate(nickname.value) != null) {
      issue.value = 'invalid_name';
      return false;
    }
    if (_identityVersion != identity.profile?.version ||
        draft.value?.version != companion.profile.value?.version) {
      issue.value = 'conflict';
      return false;
    }
    busy.value = true;
    issue.value = null;
    try {
      if (editing.value == ProfileEditField.nickname) {
        await identity.save(
          playerName: nickname.value,
          agentName: identity.profile!.agentName,
        );
      } else {
        await companion.save(draft.value!);
      }
      if (!active) return false;
      busy.value = false;
      cancelEdit();
      return true;
    } catch (e) {
      if (active) {
        issue.value =
            e is CompanionProfileException &&
                    e.failure == CompanionProfileFailure.conflict ||
                e is IdentityException && e.failure == IdentityFailure.conflict
            ? 'conflict'
            : 'unavailable';
      }
      return false;
    } finally {
      if (active) busy.value = false;
    }
  }

  @override
  void onClose() {
    _retired = true;
    editing.value = null;
    draft.value = null;
    nickname.value = '';
    super.onClose();
  }
}
