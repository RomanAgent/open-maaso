import 'dart:collection';

import 'package:maaso/src/core/foundation/app_localization.dart';

enum SkillVisibility {
  private,
  public,
  unknown;

  static SkillVisibility? fromWire(Object? value) {
    return switch (_string(value)) {
      'private' => SkillVisibility.private,
      'public' => SkillVisibility.public,
      _ => null,
    };
  }

  String get wireValue => switch (this) {
    SkillVisibility.private => 'private',
    SkillVisibility.public => 'public',
    SkillVisibility.unknown => 'unknown',
  };
}

enum SkillSafetyStatus {
  pending,
  passed,
  rejected,
  disabled,
  unknown;

  static SkillSafetyStatus? fromWire(Object? value) {
    return switch (_string(value)) {
      'pending' => SkillSafetyStatus.pending,
      'passed' => SkillSafetyStatus.passed,
      'rejected' => SkillSafetyStatus.rejected,
      'disabled' => SkillSafetyStatus.disabled,
      _ => null,
    };
  }

  String get wireValue => switch (this) {
    SkillSafetyStatus.pending => 'pending',
    SkillSafetyStatus.passed => 'passed',
    SkillSafetyStatus.rejected => 'rejected',
    SkillSafetyStatus.disabled => 'disabled',
    SkillSafetyStatus.unknown => 'unknown',
  };
}

enum SkillCategory {
  observation,
  reasoning,
  collaboration,
  unknown;

  static SkillCategory fromWire(Object? value) {
    return switch (_string(value)) {
      'observation' => SkillCategory.observation,
      'reasoning' => SkillCategory.reasoning,
      'collaboration' => SkillCategory.collaboration,
      _ => SkillCategory.unknown,
    };
  }

  String get wireValue => switch (this) {
    SkillCategory.observation => 'observation',
    SkillCategory.reasoning => 'reasoning',
    SkillCategory.collaboration => 'collaboration',
    SkillCategory.unknown => 'unknown',
  };

  String get displayName => switch (this) {
    SkillCategory.observation => 'skill.category.observation'.tr,
    SkillCategory.reasoning => 'skill.category.reasoning'.tr,
    SkillCategory.collaboration => 'skill.category.collaboration'.tr,
    SkillCategory.unknown => 'skill.category.unknown'.tr,
  };
}

enum SkillTrainingSource {
  conversation,
  behavior,
  trial;

  String get wireValue => name;
}

enum SkillInstallationStatus {
  active,
  disabled,
  uninstalled,
  unknown;

  static SkillInstallationStatus fromWire(Object? value) {
    return switch (_string(value)) {
      'active' => SkillInstallationStatus.active,
      'disabled' => SkillInstallationStatus.disabled,
      'uninstalled' => SkillInstallationStatus.uninstalled,
      _ => SkillInstallationStatus.unknown,
    };
  }

  String get wireValue => name;
}

enum MasteryBucket {
  newSkill,
  growing,
  confident,
  expert;

  static MasteryBucket fromWire(Object? value) {
    return switch (_string(value)) {
      'growing' => MasteryBucket.growing,
      'confident' => MasteryBucket.confident,
      'expert' => MasteryBucket.expert,
      _ => MasteryBucket.newSkill,
    };
  }

  String get wireValue => switch (this) {
    MasteryBucket.newSkill => 'new',
    MasteryBucket.growing => 'growing',
    MasteryBucket.confident => 'confident',
    MasteryBucket.expert => 'expert',
  };
}

class MarketplaceSkill {
  static const officialPublisherId = '00000000-0000-4000-8000-000000000001';

  const MarketplaceSkill({
    required this.skillVersionId,
    required this.submissionId,
    required this.skillKey,
    required this.title,
    required this.summary,
    required this.coverAssetUrl,
    required this.publisherId,
    required this.versionName,
    required this.permissions,
    required this.category,
    required this.instruction,
    required this.examples,
    required this.manifestDigest,
    required this.isFree,
    this.likeCount = 0,
    this.activeInstallCount = 0,
    this.likedByMe = false,
    this.visibility,
    this.safetyStatus,
    this.contentLocale = '',
  });

  final int skillVersionId;
  final int submissionId;
  final String skillKey;
  final String title;
  final String summary;
  final String coverAssetUrl;
  final String publisherId;
  final String versionName;
  final Set<String> permissions;
  final SkillCategory category;
  final String instruction;
  final List<String> examples;
  final String manifestDigest;
  final bool isFree;
  final int likeCount;
  final int activeInstallCount;
  final bool likedByMe;
  final SkillVisibility? visibility;
  final SkillSafetyStatus? safetyStatus;
  final String contentLocale;

  bool get isRejected => safetyStatus == SkillSafetyStatus.rejected;

  /// Retired host-owned starter content. Author skills with the same key are
  /// independent content and must remain available.
  bool get isRetiredOfficialSkill =>
      publisherId == officialPublisherId && skillKey == 'quick-observe';

  bool get requiresLocalizedPromptContent => publisherId == officialPublisherId;
  // Cached server cards may outlive the removed World host. Their permissions
  // stay intact for audit, but cannot become an installable capability here.
  bool get hasRetiredWorldPermissions => permissions.any(
    (permission) => permission.trim().toLowerCase().startsWith('world.'),
  );
  bool get canInstall =>
      skillVersionId > 0 &&
      !isRetiredOfficialSkill &&
      !hasRetiredWorldPermissions &&
      (safetyStatus == null || safetyStatus == SkillSafetyStatus.passed);

  factory MarketplaceSkill.fromJson(Map<String, dynamic> json) {
    return MarketplaceSkill(
      skillVersionId: _int(json['skillVersionId']),
      submissionId: _int(json['submissionId']),
      skillKey: _string(json['skillKey']),
      title: _string(json['title']),
      summary: _string(json['summary']),
      coverAssetUrl: _string(json['coverAssetUrl']),
      publisherId: _string(json['publisherId']),
      versionName: _string(json['versionName']),
      permissions: Set.unmodifiable(_stringSet(json['permissions'])),
      category: SkillCategory.fromWire(json['category']),
      instruction: _string(json['instruction']),
      examples: List.unmodifiable(_stringList(json['examples'])),
      manifestDigest: _string(json['manifestDigest']),
      isFree: json['isFree'] == true,
      likeCount: _int(json['likeCount']),
      activeInstallCount: _int(json['activeInstallCount']),
      likedByMe: json['likedByMe'] == true,
      visibility: SkillVisibility.fromWire(json['visibility']),
      safetyStatus: SkillSafetyStatus.fromWire(json['safetyStatus']),
      contentLocale: _normalizedContentLocale(
        json['contentLocale'] ?? json['locale'],
      ),
    );
  }

  MarketplaceSkill copyWithSocial(SkillSocialState social) {
    if (social.skillVersionId != skillVersionId) return this;
    return MarketplaceSkill(
      skillVersionId: skillVersionId,
      submissionId: submissionId,
      skillKey: skillKey,
      title: title,
      summary: summary,
      coverAssetUrl: coverAssetUrl,
      publisherId: publisherId,
      versionName: versionName,
      permissions: permissions,
      category: category,
      instruction: instruction,
      examples: examples,
      manifestDigest: manifestDigest,
      isFree: isFree,
      likeCount: social.likeCount,
      activeInstallCount: social.activeInstallCount,
      likedByMe: social.likedByMe,
      visibility: visibility,
      safetyStatus: safetyStatus,
      contentLocale: contentLocale,
    );
  }

  Map<String, Object?> toSanitizedJson() => {
    'skillVersionId': skillVersionId,
    'submissionId': submissionId,
    'skillKey': skillKey,
    'title': title,
    'summary': summary,
    'coverAssetUrl': coverAssetUrl,
    'publisherId': publisherId,
    'versionName': versionName,
    'permissions': permissions.toList()..sort(),
    'category': category.wireValue,
    'instruction': instruction,
    'examples': examples,
    'manifestDigest': manifestDigest,
    'isFree': isFree,
    'likeCount': likeCount,
    'activeInstallCount': activeInstallCount,
    'likedByMe': likedByMe,
    if (visibility != null) 'visibility': visibility!.wireValue,
    if (safetyStatus != null) 'safetyStatus': safetyStatus!.wireValue,
    if (contentLocale.isNotEmpty) 'contentLocale': contentLocale,
  };
}

class SkillSocialState {
  const SkillSocialState({
    required this.skillVersionId,
    required this.likeCount,
    required this.activeInstallCount,
    required this.likedByMe,
  });

  final int skillVersionId;
  final int likeCount;
  final int activeInstallCount;
  final bool likedByMe;

  factory SkillSocialState.fromJson(Map<String, dynamic> json) {
    final skillVersionId = _int(json['skillVersionId']);
    if (skillVersionId <= 0) {
      throw StateError('Skill social response is missing skillVersionId');
    }
    return SkillSocialState(
      skillVersionId: skillVersionId,
      likeCount: _int(json['likeCount']),
      activeInstallCount: _int(json['activeInstallCount']),
      likedByMe: json['likedByMe'] == true,
    );
  }
}

class MarketplaceInstallation {
  const MarketplaceInstallation({
    required this.installationId,
    required this.status,
    required this.skillVersionId,
    required this.agentId,
  });

  final int installationId;
  final SkillInstallationStatus status;
  final int skillVersionId;
  final String agentId;

  bool get isActive => status == SkillInstallationStatus.active;
  bool get isDisabled => status == SkillInstallationStatus.disabled;
  bool get isUninstalled => status == SkillInstallationStatus.uninstalled;
  bool get isInstalled => isActive || isDisabled;

  factory MarketplaceInstallation.fromJson(Map<String, dynamic> json) {
    final installationId = _int(json['installationId']);
    final skillVersionId = _int(json['skillVersionId']);
    final agentId = _string(json['agentId']);
    final status = SkillInstallationStatus.fromWire(json['status']);
    if (installationId <= 0 ||
        skillVersionId <= 0 ||
        agentId.isEmpty ||
        status == SkillInstallationStatus.unknown) {
      throw StateError('Marketplace installation response is invalid');
    }
    return MarketplaceInstallation(
      installationId: installationId,
      status: status,
      skillVersionId: skillVersionId,
      agentId: agentId,
    );
  }
}

class MarketplaceInstallResult {
  const MarketplaceInstallResult({
    required this.installationId,
    required this.status,
    required this.skillVersionId,
    required this.agentId,
  });

  final int installationId;
  final String status;
  final int skillVersionId;
  final String agentId;

  bool get isActive => status == 'active';

  MarketplaceInstallation get installation => MarketplaceInstallation(
    installationId: installationId,
    status: SkillInstallationStatus.fromWire(status),
    skillVersionId: skillVersionId,
    agentId: agentId,
  );

  factory MarketplaceInstallResult.fromJson(Map<String, dynamic> json) {
    return MarketplaceInstallResult(
      installationId: _int(json['installationId']),
      status: _string(json['status']),
      skillVersionId: _int(json['skillVersionId']),
      agentId: _string(json['agentId']),
    );
  }
}

class SkillUploadSession {
  const SkillUploadSession({
    required this.uploadId,
    required this.uploadUrl,
    required this.uploadHeaders,
    required this.expiresAt,
    required this.maxBytes,
  });

  final String uploadId;
  final Uri uploadUrl;
  final Map<String, String> uploadHeaders;
  final DateTime expiresAt;
  final int maxBytes;

  factory SkillUploadSession.fromJson(Map<String, dynamic> json) {
    final uploadUrl = Uri.tryParse(_string(json['uploadUrl']));
    if (uploadUrl == null || !uploadUrl.hasScheme) {
      throw StateError('Skill upload response is missing uploadUrl');
    }
    return SkillUploadSession(
      uploadId: _requiredString(json, 'uploadId'),
      uploadUrl: uploadUrl,
      uploadHeaders: Map.unmodifiable({
        if (json['uploadHeaders'] is Map)
          for (final entry in (json['uploadHeaders'] as Map).entries)
            if (_string(entry.key).isNotEmpty &&
                _string(entry.value).isNotEmpty)
              _string(entry.key).toLowerCase(): _string(entry.value),
      }),
      expiresAt:
          DateTime.tryParse(_requiredString(json, 'expiresAt'))?.toUtc() ??
          (throw StateError('Skill upload expiry is invalid')),
      maxBytes: _int(json['maxBytes']),
    );
  }
}

class MarketplaceSubmissionResult {
  const MarketplaceSubmissionResult({
    required this.submissionId,
    required this.skillVersionId,
    required this.status,
    required this.visibility,
    required this.safetyStatus,
  });

  final int submissionId;
  final int skillVersionId;
  final String status;
  final SkillVisibility visibility;
  final SkillSafetyStatus safetyStatus;

  factory MarketplaceSubmissionResult.fromJson(Map<String, dynamic> json) {
    final visibility = SkillVisibility.fromWire(json['visibility']);
    final safetyStatus = SkillSafetyStatus.fromWire(json['safetyStatus']);
    if (visibility == null || safetyStatus == null) {
      throw StateError('Skill submission response has invalid state');
    }
    return MarketplaceSubmissionResult(
      submissionId: _int(json['submissionId']),
      skillVersionId: _int(json['skillVersionId']),
      status: _string(json['status']),
      visibility: visibility,
      safetyStatus: safetyStatus,
    );
  }
}

class MasteryEvidenceResult {
  const MasteryEvidenceResult({required this.bucket});

  final MasteryBucket bucket;

  factory MasteryEvidenceResult.fromJson(Map<String, dynamic> json) {
    return MasteryEvidenceResult(
      bucket: MasteryBucket.fromWire(json['masteryBucket']),
    );
  }
}

enum SkillEvolutionDraftStatus {
  draft,
  published,
  unknown;

  static SkillEvolutionDraftStatus fromWire(Object? value) {
    return switch (_string(value)) {
      'draft' => SkillEvolutionDraftStatus.draft,
      'published' => SkillEvolutionDraftStatus.published,
      _ => SkillEvolutionDraftStatus.unknown,
    };
  }
}

enum SkillEvolutionTestStatus {
  passed,
  failed,
  unknown;

  static SkillEvolutionTestStatus fromWire(Object? value) {
    return switch (_string(value)) {
      'passed' => SkillEvolutionTestStatus.passed,
      'failed' => SkillEvolutionTestStatus.failed,
      _ => SkillEvolutionTestStatus.unknown,
    };
  }
}

class SkillEvolutionTrainingCase {
  const SkillEvolutionTrainingCase({
    required this.id,
    required this.prompt,
    required this.expectedBehavior,
    required this.notes,
    required this.sortOrder,
  });

  final int id;
  final String prompt;
  final String expectedBehavior;
  final String notes;
  final int sortOrder;

  factory SkillEvolutionTrainingCase.fromJson(Map<String, dynamic> json) {
    final id = _int(json['id']);
    final prompt = _requiredString(json, 'prompt');
    final expectedBehavior = _requiredString(json, 'expectedBehavior');
    if (id <= 0) {
      throw StateError('Skill training case is missing id');
    }
    return SkillEvolutionTrainingCase(
      id: id,
      prompt: prompt,
      expectedBehavior: expectedBehavior,
      notes: _string(json['notes']),
      sortOrder: _int(json['sortOrder']),
    );
  }
}

class SkillEvolutionTestRun {
  const SkillEvolutionTestRun({
    required this.id,
    required this.draftRevision,
    required this.status,
    required this.totalCases,
    required this.passedCases,
    required this.score,
    required this.report,
    required this.createdAt,
  });

  final String id;
  final int draftRevision;
  final SkillEvolutionTestStatus status;
  final int totalCases;
  final int passedCases;
  final int score;
  final Map<String, dynamic> report;
  final DateTime createdAt;

  bool get passed => status == SkillEvolutionTestStatus.passed;

  factory SkillEvolutionTestRun.fromJson(Map<String, dynamic> json) {
    final status = SkillEvolutionTestStatus.fromWire(json['status']);
    final createdAt = DateTime.tryParse(_requiredString(json, 'createdAt'));
    if (status == SkillEvolutionTestStatus.unknown || createdAt == null) {
      throw StateError('Skill standard test response is invalid');
    }
    return SkillEvolutionTestRun(
      id: _requiredString(json, 'id'),
      draftRevision: _int(json['draftRevision']),
      status: status,
      totalCases: _int(json['totalCases']),
      passedCases: _int(json['passedCases']),
      score: _int(json['score']),
      report: json['report'] is Map
          ? Map.unmodifiable(Map<String, dynamic>.from(json['report'] as Map))
          : const <String, dynamic>{},
      createdAt: createdAt.toUtc(),
    );
  }
}

class SkillEvolutionDraft {
  const SkillEvolutionDraft({
    required this.id,
    required this.sourceSkillVersionId,
    required this.rootSkillVersionId,
    required this.skillKey,
    required this.title,
    required this.summary,
    required this.coverAssetUrl,
    required this.category,
    required this.strategy,
    required this.visibility,
    required this.versionName,
    required this.status,
    required this.revision,
    required this.cases,
    required this.createdAt,
    required this.updatedAt,
    this.lastTest,
    this.publishedSkillVersionId,
  });

  final String id;
  final int sourceSkillVersionId;
  final int rootSkillVersionId;
  final String skillKey;
  final String title;
  final String summary;
  final String coverAssetUrl;
  final SkillCategory category;
  final String strategy;
  final SkillVisibility visibility;
  final String versionName;
  final SkillEvolutionDraftStatus status;
  final int revision;
  final List<SkillEvolutionTrainingCase> cases;
  final SkillEvolutionTestRun? lastTest;
  final int? publishedSkillVersionId;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isPublished => status == SkillEvolutionDraftStatus.published;
  bool get hasFreshPassingTest =>
      lastTest?.passed == true && lastTest?.draftRevision == revision;

  factory SkillEvolutionDraft.fromJson(Map<String, dynamic> json) {
    final visibility = SkillVisibility.fromWire(json['visibility']);
    final status = SkillEvolutionDraftStatus.fromWire(json['status']);
    final createdAt = DateTime.tryParse(_requiredString(json, 'createdAt'));
    final updatedAt = DateTime.tryParse(_requiredString(json, 'updatedAt'));
    if (visibility == null ||
        status == SkillEvolutionDraftStatus.unknown ||
        createdAt == null ||
        updatedAt == null) {
      throw StateError('Skill evolution draft response is invalid');
    }
    final sourceSkillVersionId = _int(json['sourceSkillVersionId']);
    final rootSkillVersionId = _int(json['rootSkillVersionId']);
    if (sourceSkillVersionId <= 0 || rootSkillVersionId <= 0) {
      throw StateError('Skill evolution draft is missing its lineage');
    }
    return SkillEvolutionDraft(
      id: _requiredString(json, 'id'),
      sourceSkillVersionId: sourceSkillVersionId,
      rootSkillVersionId: rootSkillVersionId,
      skillKey: _requiredString(json, 'skillKey'),
      title: _requiredString(json, 'title'),
      summary: _string(json['summary']),
      coverAssetUrl: _string(json['coverAssetUrl']),
      category: SkillCategory.fromWire(json['category']),
      strategy: _requiredString(json, 'strategy'),
      visibility: visibility,
      versionName: _requiredString(json, 'versionName'),
      status: status,
      revision: _int(json['revision']),
      cases: List.unmodifiable([
        for (final item
            in json['cases'] is Iterable
                ? json['cases'] as Iterable
                : const <Object?>[])
          if (item is Map)
            SkillEvolutionTrainingCase.fromJson(
              Map<String, dynamic>.from(item),
            ),
      ]),
      lastTest: json['lastTest'] is Map
          ? SkillEvolutionTestRun.fromJson(
              Map<String, dynamic>.from(json['lastTest'] as Map),
            )
          : null,
      publishedSkillVersionId: _int(json['publishedSkillVersionId']) > 0
          ? _int(json['publishedSkillVersionId'])
          : null,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
    );
  }
}

class SkillLineageNode {
  const SkillLineageNode({
    required this.skill,
    required this.rootSkillVersionId,
    required this.lineageDepth,
    required this.strategy,
    required this.isCurrent,
    this.parentSkillVersionId,
  });

  final MarketplaceSkill skill;
  final int? parentSkillVersionId;
  final int rootSkillVersionId;
  final int lineageDepth;
  final String strategy;
  final bool isCurrent;

  factory SkillLineageNode.fromJson(Map<String, dynamic> json) {
    if (json['skill'] is! Map) {
      throw StateError('Skill lineage response is missing skill');
    }
    final rootSkillVersionId = _int(json['rootSkillVersionId']);
    if (rootSkillVersionId <= 0) {
      throw StateError('Skill lineage response is missing root');
    }
    return SkillLineageNode(
      skill: MarketplaceSkill.fromJson(
        Map<String, dynamic>.from(json['skill'] as Map),
      ),
      parentSkillVersionId: _int(json['parentSkillVersionId']) > 0
          ? _int(json['parentSkillVersionId'])
          : null,
      rootSkillVersionId: rootSkillVersionId,
      lineageDepth: _int(json['lineageDepth']),
      strategy: _string(json['strategy']),
      isCurrent: json['isCurrent'] == true,
    );
  }
}

int _int(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = _string(json[key]);
  if (value.isEmpty) throw StateError('Marketplace response missing $key');
  return value;
}

String _string(Object? value, {String fallback = ''}) {
  if (value == null || value is Iterable || value is Map) return fallback;
  final text = value.toString().trim();
  return text.isEmpty ? fallback : text;
}

String _normalizedContentLocale(Object? value) {
  final raw = _string(value).toLowerCase().replaceAll('_', '-');
  if (raw == 'zh' || raw.startsWith('zh-')) return 'zh';
  if (raw == 'en' || raw.startsWith('en-')) return 'en';
  return '';
}

Set<String> _stringSet(Object? value) {
  if (value is! Iterable) return const <String>{};
  return UnmodifiableSetView({
    for (final entry in value)
      if (_string(entry).isNotEmpty) _string(entry),
  });
}

List<String> _stringList(Object? value) {
  if (value is! Iterable) return const <String>[];
  return List.unmodifiable([
    for (final entry in value)
      if (_string(entry).isNotEmpty) _string(entry),
  ]);
}
