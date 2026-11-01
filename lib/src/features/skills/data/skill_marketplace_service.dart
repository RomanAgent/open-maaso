import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/data/skill_training_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/server_request_failure_log.dart';

class SkillMarketplaceService extends AppService
    implements SkillMasteryGateway {
  SkillMarketplaceService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  final AppEnvironmentService _environment = appServices
      .find<AppEnvironmentService>();
  final AuthSessionService _auth = appServices.find<AuthSessionService>();
  final http.Client _httpClient;
  final bool _ownsClient;

  final catalog = <MarketplaceSkill>[].obs;
  final rankings = <MarketplaceSkill>[].obs;
  final mySkills = <MarketplaceSkill>[].obs;
  final evolutionDrafts = <SkillEvolutionDraft>[].obs;
  final installations = <int, MarketplaceInstallation>{}.obs;
  final isLoading = false.obs;
  final error = RxnString();

  Set<int> get installedSkillVersionIds => Set<int>.unmodifiable(
    installations.values
        .where((installation) => installation.isActive)
        .map((installation) => installation.skillVersionId),
  );

  MarketplaceInstallation? installationForVersion(int skillVersionId) =>
      installations[skillVersionId];

  bool isInstalled(MarketplaceSkill skill) =>
      isInstalledVersion(skill.skillVersionId);

  bool isInstalledVersion(int skillVersionId) =>
      installations[skillVersionId]?.isInstalled == true;

  Future<List<MarketplaceSkill>> listCatalog({String? query}) async {
    final normalizedQuery = query?.trim() ?? '';
    final uri = _environment.baseUri
        .resolve('v1/skills/catalog')
        .replace(
          queryParameters: {
            if (normalizedQuery.isNotEmpty) 'query': normalizedQuery,
            'locale': _resolvedLocaleTag(),
          },
        );
    final result = await _list(uri);
    catalog.assignAll(result);
    return result;
  }

  Future<List<MarketplaceSkill>> listRankings({String sort = 'popular'}) async {
    final normalizedSort = sort.trim().isEmpty ? 'popular' : sort.trim();
    final uri = _environment.baseUri
        .resolve('v1/skills/rankings')
        .replace(
          queryParameters: {
            'sort': normalizedSort,
            'locale': _resolvedLocaleTag(),
          },
        );
    final result = await _list(uri);
    rankings.assignAll(result);
    return result;
  }

  Future<List<MarketplaceSkill>> listMine() async {
    final result = await _list(
      _localizedGetUri(_environment.baseUri.resolve('v1/skills/mine')),
    );
    mySkills.assignAll(result);
    return result;
  }

  Future<MarketplaceSkill> getSkill(String skillId) async {
    final normalizedId = skillId.trim();
    if (normalizedId.isEmpty) throw StateError('Skill id is required');
    final data = await _request(
      _localizedGetUri(
        _environment.baseUri.resolve(
          'v1/skills/${Uri.encodeComponent(normalizedId)}',
        ),
      ),
      method: 'GET',
    );
    if (data is! Map) throw StateError('Marketplace skill response is invalid');
    return MarketplaceSkill.fromJson(Map<String, dynamic>.from(data));
  }

  Future<MarketplaceInstallResult> install({
    required String skillId,
    required String agentId,
    required Set<String> acceptedPermissions,
  }) async {
    final normalizedId = skillId.trim();
    final normalizedAgentId = agentId.trim();
    if (normalizedId.isEmpty || normalizedAgentId.isEmpty) {
      throw StateError('Skill and agent are required');
    }
    final permissions = _normalizedPermissions(acceptedPermissions);
    final uri = _environment.baseUri.resolve(
      'v1/skills/${Uri.encodeComponent(normalizedId)}/install',
    );
    debugPrint(
      '[SkillInstall][HTTP] POST ${uri.path} '
      'permissions=${permissions.length}',
    );
    final data = await _request(
      uri,
      method: 'POST',
      body: {'agentId': normalizedAgentId, 'acceptedPermissions': permissions},
    );
    if (data is! Map) {
      throw StateError('Marketplace installation response is invalid');
    }
    final result = MarketplaceInstallResult.fromJson(
      Map<String, dynamic>.from(data),
    );
    if (result.isActive) {
      final wasActive = installations[result.skillVersionId]?.isActive == true;
      installations[result.skillVersionId] = result.installation;
      if (!wasActive) {
        _applyActiveInstallDelta(result.skillVersionId, 1);
      }
    }
    debugPrint(
      '[SkillInstall][HTTP] response '
      'version=${result.skillVersionId} status=${result.status} '
      'installation=${result.installationId}',
    );
    return result;
  }

  Future<List<MarketplaceInstallation>> listInstallations({
    required String agentId,
  }) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty) throw StateError('Agent id is required');
    final uri = _environment.baseUri
        .resolve('v1/skills/installations')
        .replace(queryParameters: {'agentId': normalizedAgentId});
    final data = await _request(uri, method: 'GET');
    if (data is! List) {
      throw StateError('Marketplace installation list is invalid');
    }
    final result = [
      for (final item in data)
        if (item is Map)
          MarketplaceInstallation.fromJson(Map<String, dynamic>.from(item)),
    ];
    installations
      ..clear()
      ..addEntries(
        result.map(
          (installation) => MapEntry(installation.skillVersionId, installation),
        ),
      );
    return List.unmodifiable(result);
  }

  Future<MarketplaceInstallation> setInstallationStatus({
    required int installationId,
    required SkillInstallationStatus status,
    required String reason,
  }) async {
    if (installationId <= 0 ||
        status == SkillInstallationStatus.unknown ||
        reason.trim().isEmpty) {
      throw StateError('Installation status and reason are required');
    }
    MarketplaceInstallation? previous;
    for (final installation in installations.values) {
      if (installation.installationId == installationId) {
        previous = installation;
        break;
      }
    }
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/skills/installations/$installationId/status',
      ),
      method: 'POST',
      body: {'status': status.wireValue, 'reason': reason.trim()},
    );
    if (data is! Map) {
      throw StateError('Marketplace installation response is invalid');
    }
    final result = MarketplaceInstallation.fromJson(
      Map<String, dynamic>.from(data),
    );
    installations[result.skillVersionId] = result;
    final wasActive = previous?.isActive == true;
    if (wasActive != result.isActive) {
      _applyActiveInstallDelta(result.skillVersionId, result.isActive ? 1 : -1);
    }
    return result;
  }

  Future<SkillSocialState> setLike({
    required int skillVersionId,
    required bool liked,
  }) async {
    if (skillVersionId <= 0) throw StateError('Skill version is required');
    final data = await _request(
      _environment.baseUri.resolve('v1/skills/$skillVersionId/likes/status'),
      method: 'POST',
      body: {'liked': liked},
    );
    if (data is! Map) {
      throw StateError('Marketplace like response is invalid');
    }
    final social = SkillSocialState.fromJson(Map<String, dynamic>.from(data));
    _applySocialState(catalog, social);
    _applySocialState(rankings, social);
    _applySocialState(mySkills, social);
    return social;
  }

  Future<SkillUploadSession> createUpload({
    required int contentLength,
    required String sha256Digest,
  }) async {
    final data = await _request(
      _environment.baseUri.resolve('v1/skills/uploads'),
      method: 'POST',
      body: {'contentLength': contentLength, 'sha256': sha256Digest},
    );
    if (data is! Map) {
      throw StateError('Skill upload response is invalid');
    }
    return SkillUploadSession.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> completeUpload(String uploadId) async {
    final normalizedId = uploadId.trim();
    if (normalizedId.isEmpty) throw StateError('Skill upload id is required');
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/skills/uploads/${Uri.encodeComponent(normalizedId)}/complete',
      ),
      method: 'POST',
      body: const <String, dynamic>{},
    );
    if (data is! Map || data['status']?.toString().trim() != 'ready') {
      throw StateError('Skill upload was not ready');
    }
  }

  Future<MarketplaceSubmissionResult> submit({
    required String uploadId,
    required SkillVisibility visibility,
    required String versionName,
    String coverAssetUrl = '',
  }) async {
    if (visibility == SkillVisibility.unknown) {
      throw StateError('Select private or public visibility');
    }
    final data = await _request(
      _environment.baseUri.resolve('v1/skills/submissions'),
      method: 'POST',
      body: {
        'uploadId': uploadId.trim(),
        'visibility': visibility.wireValue,
        'versionName': versionName.trim(),
        'coverAssetUrl': coverAssetUrl.trim(),
      },
    );
    if (data is! Map) throw StateError('Skill submission response is invalid');
    return MarketplaceSubmissionResult.fromJson(
      Map<String, dynamic>.from(data),
    );
  }

  Future<MarketplaceSubmissionResult> uploadAndSubmit({
    required File package,
    required SkillVisibility visibility,
    required String versionName,
    String coverAssetUrl = '',
  }) async {
    final length = await package.length();
    final digest = await sha256.bind(package.openRead()).single;
    final session = await createUpload(
      contentLength: length,
      sha256Digest: digest.toString(),
    );
    if (length > session.maxBytes) {
      throw StateError('Skill package exceeds the server upload limit');
    }
    final response = await _httpClient.put(
      session.uploadUrl,
      headers: session.uploadHeaders,
      body: await package.readAsBytes(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      ServerRequestFailureLog.response(
        source: 'SkillMarketplace',
        method: 'PUT',
        uri: session.uploadUrl,
        statusCode: response.statusCode,
        responseBody: response.body,
      );
      throw StateError(
        'Skill package upload failed: HTTP ${response.statusCode}',
      );
    }
    await completeUpload(session.uploadId);
    return submit(
      uploadId: session.uploadId,
      visibility: visibility,
      versionName: versionName,
      coverAssetUrl: coverAssetUrl,
    );
  }

  Future<SkillEvolutionDraft> forkSkill(int skillVersionId) async {
    if (skillVersionId <= 0) throw StateError('Skill version is required');
    final data = await _request(
      _environment.baseUri.resolve('v1/skills/$skillVersionId/forks'),
      method: 'POST',
      body: const <String, dynamic>{},
    );
    final draft = _decodeEvolutionDraft(data);
    evolutionDrafts.insert(0, draft);
    return draft;
  }

  Future<List<SkillEvolutionDraft>> listEvolutionDrafts() async {
    final data = await _request(
      _environment.baseUri.resolve('v1/skills/drafts'),
      method: 'GET',
    );
    if (data is! List) {
      throw StateError('Skill evolution draft list is invalid');
    }
    final result = [
      for (final item in data)
        if (item is Map)
          SkillEvolutionDraft.fromJson(Map<String, dynamic>.from(item)),
    ];
    evolutionDrafts.assignAll(result);
    return List.unmodifiable(result);
  }

  Future<SkillEvolutionDraft> getEvolutionDraft(String draftId) async {
    final normalizedDraftId = draftId.trim();
    if (normalizedDraftId.isEmpty) throw StateError('Skill draft is required');
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/skills/drafts/${Uri.encodeComponent(normalizedDraftId)}',
      ),
      method: 'GET',
    );
    return _rememberEvolutionDraft(_decodeEvolutionDraft(data));
  }

  Future<SkillEvolutionDraft> updateEvolutionDraft({
    required String draftId,
    required String title,
    required String summary,
    required String strategy,
    required SkillVisibility visibility,
    required String versionName,
  }) async {
    final normalizedDraftId = draftId.trim();
    if (normalizedDraftId.isEmpty ||
        title.trim().isEmpty ||
        strategy.trim().isEmpty ||
        versionName.trim().isEmpty ||
        visibility == SkillVisibility.unknown) {
      throw StateError('Complete the Skill evolution draft before saving');
    }
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/skills/drafts/${Uri.encodeComponent(normalizedDraftId)}',
      ),
      method: 'PATCH',
      body: {
        'title': title.trim(),
        'summary': summary.trim(),
        'strategy': strategy.trim(),
        'visibility': visibility.wireValue,
        'versionName': versionName.trim(),
      },
    );
    return _rememberEvolutionDraft(_decodeEvolutionDraft(data));
  }

  Future<SkillEvolutionDraft> addEvolutionCase({
    required String draftId,
    required String prompt,
    required String expectedBehavior,
    String notes = '',
  }) async {
    final normalizedDraftId = draftId.trim();
    if (normalizedDraftId.isEmpty ||
        prompt.trim().isEmpty ||
        expectedBehavior.trim().isEmpty) {
      throw StateError('Prompt and expected behavior are required');
    }
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/skills/drafts/${Uri.encodeComponent(normalizedDraftId)}/cases',
      ),
      method: 'POST',
      body: {
        'prompt': prompt.trim(),
        'expectedBehavior': expectedBehavior.trim(),
        'notes': notes.trim(),
      },
    );
    return _rememberEvolutionDraft(_decodeEvolutionDraft(data));
  }

  Future<SkillEvolutionDraft> deleteEvolutionCase({
    required String draftId,
    required int caseId,
  }) async {
    final normalizedDraftId = draftId.trim();
    if (normalizedDraftId.isEmpty || caseId <= 0) {
      throw StateError('Skill training case is required');
    }
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/skills/drafts/${Uri.encodeComponent(normalizedDraftId)}/cases/$caseId',
      ),
      method: 'DELETE',
    );
    return _rememberEvolutionDraft(_decodeEvolutionDraft(data));
  }

  Future<SkillEvolutionDraft> runEvolutionStandardTest(String draftId) async {
    final normalizedDraftId = draftId.trim();
    if (normalizedDraftId.isEmpty) throw StateError('Skill draft is required');
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/skills/drafts/${Uri.encodeComponent(normalizedDraftId)}/tests',
      ),
      method: 'POST',
      body: const <String, dynamic>{},
    );
    return _rememberEvolutionDraft(_decodeEvolutionDraft(data));
  }

  Future<MarketplaceSubmissionResult> publishEvolutionDraft(
    String draftId,
  ) async {
    final normalizedDraftId = draftId.trim();
    if (normalizedDraftId.isEmpty) throw StateError('Skill draft is required');
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/skills/drafts/${Uri.encodeComponent(normalizedDraftId)}/publish',
      ),
      method: 'POST',
      body: const <String, dynamic>{},
    );
    if (data is! Map) {
      throw StateError('Skill evolution publish response is invalid');
    }
    return MarketplaceSubmissionResult.fromJson(
      Map<String, dynamic>.from(data),
    );
  }

  Future<List<SkillLineageNode>> getSkillLineage(int skillVersionId) async {
    if (skillVersionId <= 0) throw StateError('Skill version is required');
    final data = await _request(
      _localizedGetUri(
        _environment.baseUri.resolve('v1/skills/$skillVersionId/lineage'),
      ),
      method: 'GET',
    );
    if (data is! List) {
      throw StateError('Skill lineage response is invalid');
    }
    return List.unmodifiable([
      for (final item in data)
        if (item is Map)
          SkillLineageNode.fromJson(Map<String, dynamic>.from(item)),
    ]);
  }

  @override
  Future<MasteryEvidenceResult> recordMasteryEvidence({
    required String agentId,
    required String eventId,
    required int skillVersionId,
    required SkillTrainingSource source,
    required int quality,
    required String digest,
    required DateTime occurredAt,
  }) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty) throw StateError('Agent id is required');
    final data = await _request(
      _environment.baseUri.resolve(
        'v1/agents/${Uri.encodeComponent(normalizedAgentId)}/skill-mastery/events',
      ),
      method: 'POST',
      body: {
        'eventId': eventId.trim(),
        'skillVersionId': skillVersionId,
        'source': source.wireValue,
        'quality': quality,
        'digest': digest.trim(),
        'occurredAt': occurredAt.toUtc().toIso8601String(),
      },
    );
    if (data is! Map) {
      throw StateError('Skill mastery response is invalid');
    }
    return MasteryEvidenceResult.fromJson(Map<String, dynamic>.from(data));
  }

  Future<List<MarketplaceSkill>> _list(Uri uri) async {
    final data = await _request(uri, method: 'GET');
    if (data is! List) {
      throw StateError('Marketplace catalog response is invalid');
    }
    return [
          for (final item in data)
            if (item is Map)
              MarketplaceSkill.fromJson(Map<String, dynamic>.from(item)),
        ]
        .where(
          (skill) =>
              !skill.isRetiredOfficialSkill &&
              !skill.hasRetiredWorldPermissions,
        )
        .toList(growable: false);
  }

  Future<Object?> _request(
    Uri uri, {
    required String method,
    Map<String, dynamic>? body,
  }) async {
    isLoading.value = true;
    error.value = null;
    try {
      final token = await _accessToken();
      final headers = <String, String>{
        'Authorization': 'Bearer $token',
        if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      };
      late final http.Response response;
      try {
        response = switch (method) {
          'GET' => await _httpClient.get(uri, headers: headers),
          'POST' => await _httpClient.post(
            uri,
            headers: headers,
            body: jsonEncode(body),
          ),
          'PATCH' => await _httpClient.patch(
            uri,
            headers: headers,
            body: jsonEncode(body),
          ),
          'DELETE' => await _httpClient.delete(
            uri,
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          ),
          _ => throw UnsupportedError(
            'Unsupported marketplace method: $method',
          ),
        };
      } catch (exception, stackTrace) {
        ServerRequestFailureLog.transport(
          source: 'SkillMarketplace',
          method: method,
          uri: uri,
          error: exception,
          stackTrace: stackTrace,
        );
        rethrow;
      }
      try {
        Object? decoded;
        try {
          decoded = response.body.trim().isEmpty
              ? const <String, dynamic>{}
              : jsonDecode(response.body);
        } on FormatException {
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw StateError(
              'Marketplace request failed: HTTP ${response.statusCode}',
            );
          }
          rethrow;
        }
        if (decoded is! Map) {
          throw StateError('Marketplace response is invalid');
        }
        final envelope = Map<String, dynamic>.from(decoded);
        final code = envelope['code']?.toString().trim();
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            (code != null && code.isNotEmpty && code != 'OK')) {
          final message = envelope['message']?.toString().trim();
          throw StateError(
            message == null || message.isEmpty
                ? 'Marketplace request failed: HTTP ${response.statusCode}'
                : message,
          );
        }
        return envelope['data'];
      } catch (exception, stackTrace) {
        ServerRequestFailureLog.response(
          source: 'SkillMarketplace',
          method: method,
          uri: uri,
          statusCode: response.statusCode,
          responseBody: response.body,
          error: exception,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    } catch (exception) {
      error.value = exception.toString().replaceFirst('Bad state: ', '');
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  Future<String> _accessToken() async {
    final current = _auth.session.value;
    if (current != null && current.isValid) return current.accessToken;
    final restored = await _auth.restoreOrRefresh();
    final refreshed = _auth.session.value;
    if (!restored || refreshed == null || !refreshed.isValid) {
      throw StateError('Sign in is required to use the skill marketplace');
    }
    return refreshed.accessToken;
  }

  @override
  void onClose() {
    if (_ownsClient) _httpClient.close();
    super.onClose();
  }

  void _applyActiveInstallDelta(int skillVersionId, int delta) {
    for (final target in [catalog, rankings, mySkills]) {
      final index = target.indexWhere(
        (skill) => skill.skillVersionId == skillVersionId,
      );
      if (index < 0) continue;
      final skill = target[index];
      final nextCount = skill.activeInstallCount + delta;
      target[index] = skill.copyWithSocial(
        SkillSocialState(
          skillVersionId: skillVersionId,
          likeCount: skill.likeCount,
          activeInstallCount: nextCount < 0 ? 0 : nextCount,
          likedByMe: skill.likedByMe,
        ),
      );
    }
  }

  SkillEvolutionDraft _rememberEvolutionDraft(SkillEvolutionDraft draft) {
    final index = evolutionDrafts.indexWhere((item) => item.id == draft.id);
    if (index < 0) {
      evolutionDrafts.insert(0, draft);
    } else {
      evolutionDrafts[index] = draft;
    }
    return draft;
  }
}

Uri _localizedGetUri(Uri uri) => uri.replace(
  queryParameters: {...uri.queryParameters, 'locale': _resolvedLocaleTag()},
);

String _resolvedLocaleTag() =>
    (appServices.maybeFind<LocaleConfigService>()?.resolvedAppLocale ??
            AppLocale.en)
        .code;

SkillEvolutionDraft _decodeEvolutionDraft(Object? data) {
  if (data is! Map) {
    throw StateError('Skill evolution draft response is invalid');
  }
  return SkillEvolutionDraft.fromJson(Map<String, dynamic>.from(data));
}

void _applySocialState(
  RxList<MarketplaceSkill> target,
  SkillSocialState social,
) {
  final index = target.indexWhere(
    (skill) => skill.skillVersionId == social.skillVersionId,
  );
  if (index < 0) return;
  target[index] = target[index].copyWithSocial(social);
}

List<String> _normalizedPermissions(Set<String> acceptedPermissions) {
  if (acceptedPermissions.any(
    (permission) => permission.trim().toLowerCase().startsWith('world.'),
  )) {
    throw StateError('Retired World permissions are unavailable');
  }
  final permissions =
      acceptedPermissions
          .map((permission) => permission.trim())
          .where((permission) => permission.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  return permissions;
}
