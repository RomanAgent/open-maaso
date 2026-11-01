import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_service.dart';

class SkillStoreController extends AppController {
  final SkillMarketplaceService _marketplace = appServices
      .find<SkillMarketplaceService>();
  final AgentCoreController _core = appServices.find<AgentCoreController>();
  final InstalledSkillRegistry _installed = appServices
      .find<InstalledSkillRegistry>();

  final skills = <MarketplaceSkill>[].obs;
  final rankedSkills = <MarketplaceSkill>[].obs;
  final mySkills = <MarketplaceSkill>[].obs;
  final evolutionDrafts = <SkillEvolutionDraft>[].obs;
  final isLoading = false.obs;
  final isUploading = false.obs;
  final installingVersionIds = <int>{}.obs;
  final likingVersionIds = <int>{}.obs;
  final changingInstallationVersionIds = <int>{}.obs;
  final selectedPackage = Rxn<File>();
  final uploadVisibility = SkillVisibility.private.obs;
  final error = RxnString();

  String get _selfAgentId =>
      _core.profile.value?.userId.trim().isNotEmpty == true
      ? _core.profile.value!.userId
      : 'self';

  @override
  void onInit() {
    super.onInit();
    scheduleMicrotask(() {
      if (!isClosed) unawaited(reload());
    });
  }

  Future<void> reload({String? query}) async {
    isLoading.value = true;
    error.value = null;
    try {
      await Future.wait<void>([
        _marketplace
            .listCatalog(query: query)
            .then((result) => skills.assignAll(result)),
        _marketplace.listRankings().then(
          (result) => rankedSkills.assignAll(result),
        ),
        _marketplace.listMine().then((result) => mySkills.assignAll(result)),
        _marketplace.listEvolutionDrafts().then(
          (result) => evolutionDrafts.assignAll(result),
        ),
        _marketplace.listInstallations(agentId: _selfAgentId).then((_) {}),
      ]);
      await _syncInstalledRegistry();
    } catch (exception) {
      error.value = _failureMessage(exception);
    } finally {
      isLoading.value = false;
    }
  }

  bool isInstalled(MarketplaceSkill skill) => _marketplace.isInstalled(skill);

  bool isInstalling(MarketplaceSkill skill) =>
      installingVersionIds.contains(skill.skillVersionId);

  bool isLiking(MarketplaceSkill skill) =>
      likingVersionIds.contains(skill.skillVersionId);

  bool isChangingInstallation(MarketplaceSkill skill) =>
      changingInstallationVersionIds.contains(skill.skillVersionId);

  MarketplaceInstallation? installationFor(MarketplaceSkill skill) =>
      _marketplace.installationForVersion(skill.skillVersionId);

  List<MarketplaceSkill> get installedSkills {
    final byVersion = <int, MarketplaceSkill>{};
    for (final skill in [...skills, ...rankedSkills, ...mySkills]) {
      if (skill.skillVersionId > 0 && isInstalled(skill)) {
        byVersion[skill.skillVersionId] = skill;
      }
    }
    final result = byVersion.values.toList()
      ..sort((left, right) => left.title.compareTo(right.title));
    return List.unmodifiable(result);
  }

  Future<void> install(
    MarketplaceSkill skill,
    Set<String> acceptedPermissions,
  ) async {
    debugPrint(
      '[SkillInstall][Controller] start '
      'version=${skill.skillVersionId} canInstall=${skill.canInstall} '
      'requested=${skill.permissions.length} accepted=${acceptedPermissions.length}',
    );
    if (!skill.canInstall) {
      debugPrint(
        '[SkillInstall][Controller] rejected locally '
        'version=${skill.skillVersionId} safety=${skill.safetyStatus?.wireValue}',
      );
      throw StateError('This Skill is not available for installation');
    }
    if (!acceptedPermissions.containsAll(skill.permissions) ||
        acceptedPermissions.length != skill.permissions.length) {
      throw StateError('skill_store.accept_permissions_required'.tr);
    }
    installingVersionIds.add(skill.skillVersionId);
    error.value = null;
    try {
      final result = await _marketplace.install(
        skillId: skill.skillVersionId.toString(),
        agentId: _selfAgentId,
        acceptedPermissions: acceptedPermissions,
      );
      if (!result.isActive) {
        throw StateError('The server did not activate this Skill');
      }
      await _installed.upsert(agentId: _selfAgentId, skill: skill);
      await _refreshRuntime();
      _refreshSkillLists();
      debugPrint(
        '[SkillInstall][Controller] completed '
        'version=${skill.skillVersionId} status=${result.status}',
      );
    } catch (exception) {
      error.value = _failureMessage(exception);
      debugPrint(
        '[SkillInstall][Controller] failed '
        'version=${skill.skillVersionId} error=$exception',
      );
      rethrow;
    } finally {
      installingVersionIds.remove(skill.skillVersionId);
    }
  }

  Future<void> toggleLike(MarketplaceSkill skill) async {
    if (isLiking(skill)) return;
    likingVersionIds.add(skill.skillVersionId);
    error.value = null;
    try {
      await _marketplace.setLike(
        skillVersionId: skill.skillVersionId,
        liked: !skill.likedByMe,
      );
      _copyMarketplaceLists();
    } catch (exception) {
      error.value = _failureMessage(exception);
      rethrow;
    } finally {
      likingVersionIds.remove(skill.skillVersionId);
    }
  }

  Future<void> setInstallationStatus(
    MarketplaceSkill skill,
    SkillInstallationStatus status,
  ) async {
    if (status == SkillInstallationStatus.active &&
        skill.hasRetiredWorldPermissions) {
      throw StateError('Retired World permissions are unavailable');
    }
    final installation = installationFor(skill);
    if (installation == null) {
      throw StateError('Installation state is unavailable');
    }
    if (isChangingInstallation(skill)) return;
    changingInstallationVersionIds.add(skill.skillVersionId);
    error.value = null;
    try {
      final updated = await _marketplace.setInstallationStatus(
        installationId: installation.installationId,
        status: status,
        reason: switch (status) {
          SkillInstallationStatus.active => 'enabled by owner',
          SkillInstallationStatus.disabled => 'paused by owner',
          SkillInstallationStatus.uninstalled => 'removed by owner',
          SkillInstallationStatus.unknown => 'invalid',
        },
      );
      if (updated.isActive) {
        await _installed.upsert(agentId: _selfAgentId, skill: skill);
      } else {
        await _installed.remove(
          agentId: _selfAgentId,
          skillVersionId: skill.skillVersionId,
        );
      }
      await _refreshRuntime();
      _refreshSkillLists();
    } catch (exception) {
      error.value = _failureMessage(exception);
      rethrow;
    } finally {
      changingInstallationVersionIds.remove(skill.skillVersionId);
    }
  }

  Future<void> choosePackage() async {
    final selection = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['maaso-skill', 'zip'],
    );
    if (selection == null) return;
    final path = selection.path;
    if (path == null || path.trim().isEmpty) return;
    selectedPackage.value = File(path);
  }

  void clearPackage() => selectedPackage.value = null;

  Future<MarketplaceSubmissionResult> uploadSelected({
    required String versionName,
  }) async {
    final package = selectedPackage.value;
    if (package == null) {
      throw StateError('Choose a .maaso-skill package first');
    }
    final normalizedVersion = versionName.trim();
    if (normalizedVersion.isEmpty) {
      throw StateError('skill_store.version_required'.tr);
    }
    isUploading.value = true;
    error.value = null;
    try {
      final result = await _marketplace.uploadAndSubmit(
        package: package,
        visibility: uploadVisibility.value,
        versionName: normalizedVersion,
      );
      await reload();
      if (result.safetyStatus == SkillSafetyStatus.passed) {
        selectedPackage.value = null;
      }
      return result;
    } catch (exception) {
      error.value = _failureMessage(exception);
      rethrow;
    } finally {
      isUploading.value = false;
    }
  }

  String _failureMessage(Object exception) {
    debugPrint('[SkillStore] request failed: $exception');
    return 'common.request_failed'.tr;
  }

  Future<void> _syncInstalledRegistry() async {
    final active = <int, MarketplaceSkill>{};
    for (final skill in [...skills, ...rankedSkills, ...mySkills]) {
      if (skill.skillVersionId > 0 &&
          _marketplace.installationForVersion(skill.skillVersionId)?.isActive ==
              true) {
        active[skill.skillVersionId] = skill;
      }
    }
    await _installed.syncActiveSkills(
      agentId: _selfAgentId,
      skills: active.values,
    );
    await _refreshRuntime();
  }

  void _copyMarketplaceLists() {
    skills.assignAll(_marketplace.catalog);
    rankedSkills.assignAll(_marketplace.rankings);
    mySkills.assignAll(_marketplace.mySkills);
  }

  void _refreshSkillLists() {
    skills.refresh();
    rankedSkills.refresh();
    mySkills.refresh();
  }

  Future<void> _refreshRuntime() {
    return appServices.find<AgentRuntimeRegistry>().refreshInstalledSkills(
      _selfAgentId,
    );
  }
}
