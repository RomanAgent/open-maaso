enum CreatorDraftKind {
  agentNews('agent_news'),
  aiNews('ai_news'),
  column('column'),
  novel('novel'),
  illustratedPost('illustrated_post'),
  selfieVideo('selfie_video');

  const CreatorDraftKind(this.wireValue);

  final String wireValue;

  static CreatorDraftKind parse(Object? value) => values.firstWhere(
    (candidate) => candidate.wireValue == value,
    orElse: () => throw const FormatException('Invalid creator draft kind'),
  );
}

enum CreatorDraftStatus {
  draft,
  generating,
  ready,
  submitted,
  published,
  rejected;

  static CreatorDraftStatus parse(Object? value) => values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () => throw const FormatException('Invalid creator draft status'),
  );
}

class CreatorDraftBlock {
  const CreatorDraftBlock({required this.type, required this.text});

  static const Set<String> allowedTypes = <String>{
    'heading',
    'paragraph',
    'quote',
    'callout',
  };

  final String type;
  final String text;

  factory CreatorDraftBlock.fromJson(Map<String, Object?> json) {
    if (json.keys.any((key) => key != 'type' && key != 'text')) {
      throw const FormatException('Unsupported creator block field');
    }
    final type = json['type']?.toString().trim() ?? '';
    final text = json['text']?.toString().trim() ?? '';
    if (!allowedTypes.contains(type) || text.isEmpty || text.length > 4000) {
      throw const FormatException('Invalid creator draft block');
    }
    return CreatorDraftBlock(type: type, text: text);
  }

  Map<String, Object> toJson() => <String, Object>{'type': type, 'text': text};
}

class CreatorAssetRef {
  const CreatorAssetRef({
    required this.id,
    required this.localPath,
    required this.contentType,
    required this.sha256,
    required this.bytes,
    required this.width,
    required this.height,
  });

  final String id;
  final String localPath;
  final String contentType;
  final String sha256;
  final int bytes;
  final int width;
  final int height;

  factory CreatorAssetRef.fromJson(Map<String, Object?> json) {
    _requireOnly(json, const <String>{
      'id',
      'localPath',
      'contentType',
      'sha256',
      'bytes',
      'width',
      'height',
    });
    final id = json['id']?.toString().trim() ?? '';
    final localPath = json['localPath']?.toString().trim() ?? '';
    final contentType = json['contentType']?.toString().trim() ?? '';
    final sha256 = json['sha256']?.toString().trim().toLowerCase() ?? '';
    final bytes = _int(json['bytes']);
    final width = _int(json['width']);
    final height = _int(json['height']);
    if (id.isEmpty ||
        localPath.isEmpty ||
        !const <String>{'image/png', 'image/jpeg'}.contains(contentType) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        bytes <= 0 ||
        width <= 0 ||
        height <= 0) {
      throw const FormatException('Invalid creator asset');
    }
    return CreatorAssetRef(
      id: id,
      localPath: localPath,
      contentType: contentType,
      sha256: sha256,
      bytes: bytes,
      width: width,
      height: height,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'localPath': localPath,
    'contentType': contentType,
    'sha256': sha256,
    'bytes': bytes,
    'width': width,
    'height': height,
  };
}

class CreatorDraftSource {
  const CreatorDraftSource({
    required this.sourceId,
    required this.displayName,
    required this.canonicalUrl,
    required this.publishedAt,
    required this.citationText,
  });

  final String sourceId;
  final String displayName;
  final Uri canonicalUrl;
  final DateTime publishedAt;
  final String citationText;

  factory CreatorDraftSource.fromJson(Map<String, Object?> json) {
    _requireOnly(json, const <String>{
      'sourceId',
      'displayName',
      'canonicalUrl',
      'publishedAt',
      'citationText',
    });
    final sourceId = json['sourceId']?.toString().trim() ?? '';
    final displayName = json['displayName']?.toString().trim() ?? '';
    final canonicalUrl = _publicHttpsUri(json['canonicalUrl']);
    final publishedAt = DateTime.tryParse(
      json['publishedAt']?.toString() ?? '',
    );
    final citationText = json['citationText']?.toString().trim() ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(sourceId) ||
        displayName.isEmpty ||
        displayName.length > 120 ||
        publishedAt == null ||
        citationText.isEmpty ||
        citationText.length > 500) {
      throw const FormatException('Invalid creator source');
    }
    return CreatorDraftSource(
      sourceId: sourceId,
      displayName: displayName,
      canonicalUrl: canonicalUrl,
      publishedAt: publishedAt.toLocal(),
      citationText: citationText,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'sourceId': sourceId,
    'displayName': displayName,
    'canonicalUrl': canonicalUrl.toString(),
    'publishedAt': publishedAt.toUtc().toIso8601String(),
    'citationText': citationText,
  };
}

class CreatorDraftFactLayer {
  const CreatorDraftFactLayer({required this.summary, required this.sourceIds});

  final String summary;
  final List<String> sourceIds;

  factory CreatorDraftFactLayer.fromJson(Map<String, Object?> json) {
    _requireOnly(json, const <String>{'summary', 'sourceIds'});
    final summary = json['summary']?.toString().trim() ?? '';
    final rawSourceIds = json['sourceIds'];
    if (summary.isEmpty ||
        summary.length > 2000 ||
        rawSourceIds is! List ||
        rawSourceIds.isEmpty ||
        rawSourceIds.length > 12) {
      throw const FormatException('Invalid creator fact layer');
    }
    final sourceIds = rawSourceIds
        .map((raw) => raw.toString().trim())
        .toList(growable: false);
    if (sourceIds.any((id) => !RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(id))) {
      throw const FormatException('Invalid creator fact source');
    }
    return CreatorDraftFactLayer(
      summary: summary,
      sourceIds: List<String>.unmodifiable(sourceIds),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'summary': summary,
    'sourceIds': sourceIds,
  };
}

class CreatorDraftAgentverseLayer {
  const CreatorDraftAgentverseLayer({required this.label, required this.text});

  final String label;
  final String text;

  factory CreatorDraftAgentverseLayer.fromJson(Map<String, Object?> json) {
    _requireOnly(json, const <String>{'label', 'text'});
    final label = json['label']?.toString().trim() ?? '';
    final text = json['text']?.toString().trim() ?? '';
    if (label.isEmpty ||
        label.length > 120 ||
        text.isEmpty ||
        text.length > 2000) {
      throw const FormatException('Invalid creator Agentverse layer');
    }
    return CreatorDraftAgentverseLayer(label: label, text: text);
  }

  Map<String, Object> toJson() => <String, Object>{
    'label': label,
    'text': text,
  };
}

class CreatorDraft {
  const CreatorDraft({
    required this.id,
    required this.scopeKey,
    required this.kind,
    required this.status,
    required this.title,
    required this.summary,
    required this.blocks,
    required this.disclosure,
    required this.generationDisclosure,
    required this.sources,
    required this.createdAt,
    required this.updatedAt,
    this.imagePrompt,
    this.videoDirection,
    this.asset,
    this.factLayer,
    this.agentverseLayer,
  });

  final String id;
  final String scopeKey;
  final CreatorDraftKind kind;
  final CreatorDraftStatus status;
  final String title;
  final String summary;
  final List<CreatorDraftBlock> blocks;
  final String disclosure;
  final String generationDisclosure;
  final List<CreatorDraftSource> sources;
  final CreatorDraftFactLayer? factLayer;
  final CreatorDraftAgentverseLayer? agentverseLayer;
  final String? imagePrompt;
  final String? videoDirection;
  final CreatorAssetRef? asset;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isSelfieVideo => kind == CreatorDraftKind.selfieVideo;
  bool get canGenerateImage =>
      !isSelfieVideo && imagePrompt?.trim().isNotEmpty == true;

  CreatorDraft copyWith({
    CreatorDraftStatus? status,
    CreatorAssetRef? asset,
    bool clearAsset = false,
    DateTime? updatedAt,
  }) => CreatorDraft(
    id: id,
    scopeKey: scopeKey,
    kind: kind,
    status: status ?? this.status,
    title: title,
    summary: summary,
    blocks: blocks,
    disclosure: disclosure,
    generationDisclosure: generationDisclosure,
    sources: sources,
    imagePrompt: imagePrompt,
    videoDirection: videoDirection,
    asset: clearAsset ? null : asset ?? this.asset,
    factLayer: factLayer,
    agentverseLayer: agentverseLayer,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory CreatorDraft.fromJson(Map<String, Object?> json) {
    _requireOnly(json, const <String>{
      'id',
      'scopeKey',
      'kind',
      'status',
      'title',
      'summary',
      'blocks',
      'disclosure',
      'generationDisclosure',
      'sources',
      'factLayer',
      'agentverseLayer',
      'imagePrompt',
      'videoDirection',
      'asset',
      'createdAt',
      'updatedAt',
    });
    final id = json['id']?.toString().trim() ?? '';
    final scopeKey = json['scopeKey']?.toString().trim() ?? '';
    final title = json['title']?.toString().trim() ?? '';
    final summary = json['summary']?.toString().trim() ?? '';
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(json['updatedAt']?.toString() ?? '');
    final rawBlocks = json['blocks'];
    final rawSources = json['sources'];
    if (id.isEmpty ||
        scopeKey.isEmpty ||
        title.isEmpty ||
        title.length > 240 ||
        summary.length > 1200 ||
        createdAt == null ||
        updatedAt == null ||
        rawBlocks is! List ||
        rawBlocks.length > 80 ||
        rawSources is! List ||
        rawSources.length > 12) {
      throw const FormatException('Invalid creator draft');
    }
    final blocks = rawBlocks
        .map((raw) {
          if (raw is! Map) throw const FormatException('Invalid creator block');
          return CreatorDraftBlock.fromJson(Map<String, Object?>.from(raw));
        })
        .toList(growable: false);
    final kind = CreatorDraftKind.parse(json['kind']);
    final sources = rawSources
        .map((raw) {
          if (raw is! Map) {
            throw const FormatException('Invalid creator source');
          }
          return CreatorDraftSource.fromJson(Map<String, Object?>.from(raw));
        })
        .toList(growable: false);
    final factLayer = json['factLayer'] is Map
        ? CreatorDraftFactLayer.fromJson(
            Map<String, Object?>.from(json['factLayer']! as Map),
          )
        : null;
    final agentverseLayer = json['agentverseLayer'] is Map
        ? CreatorDraftAgentverseLayer.fromJson(
            Map<String, Object?>.from(json['agentverseLayer']! as Map),
          )
        : null;
    final disclosure = json['disclosure']?.toString().trim() ?? '';
    final generationDisclosure =
        json['generationDisclosure']?.toString().trim() ?? '';
    final videoDirection = _optionalText(json['videoDirection'], 1200);
    if (kind == CreatorDraftKind.selfieVideo &&
        (videoDirection == null || videoDirection.isEmpty)) {
      throw const FormatException('Selfie draft requires a direction');
    }
    _validateEditorialContract(
      kind: kind,
      blocks: blocks,
      disclosure: disclosure,
      generationDisclosure: generationDisclosure,
      sources: sources,
      factLayer: factLayer,
      agentverseLayer: agentverseLayer,
    );
    return CreatorDraft(
      id: id,
      scopeKey: scopeKey,
      kind: kind,
      status: CreatorDraftStatus.parse(json['status']),
      title: title,
      summary: summary,
      blocks: List<CreatorDraftBlock>.unmodifiable(blocks),
      disclosure: disclosure,
      generationDisclosure: generationDisclosure,
      sources: List<CreatorDraftSource>.unmodifiable(sources),
      factLayer: factLayer,
      agentverseLayer: agentverseLayer,
      imagePrompt: _optionalText(json['imagePrompt'], 1200),
      videoDirection: videoDirection,
      asset: json['asset'] is Map
          ? CreatorAssetRef.fromJson(
              Map<String, Object?>.from(json['asset']! as Map),
            )
          : null,
      createdAt: createdAt.toLocal(),
      updatedAt: updatedAt.toLocal(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'scopeKey': scopeKey,
    'kind': kind.wireValue,
    'status': status.name,
    'title': title,
    'summary': summary,
    'blocks': blocks.map((block) => block.toJson()).toList(growable: false),
    'disclosure': disclosure,
    'generationDisclosure': generationDisclosure,
    'sources': sources.map((source) => source.toJson()).toList(growable: false),
    'factLayer': factLayer?.toJson(),
    'agentverseLayer': agentverseLayer?.toJson(),
    'imagePrompt': imagePrompt,
    'videoDirection': videoDirection,
    'asset': asset?.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

void validateCreatorEditorialContract({
  required CreatorDraftKind kind,
  required List<CreatorDraftBlock> blocks,
  required List<CreatorDraftSource> sources,
  required CreatorDraftFactLayer? factLayer,
  required CreatorDraftAgentverseLayer? agentverseLayer,
}) {
  _validateEditorialContract(
    kind: kind,
    blocks: blocks,
    disclosure: creatorDisclosureFor(kind),
    generationDisclosure: creatorGenerationDisclosureFor(kind),
    sources: sources,
    factLayer: factLayer,
    agentverseLayer: agentverseLayer,
  );
}

String creatorDisclosureFor(CreatorDraftKind kind) => switch (kind) {
  CreatorDraftKind.agentNews => 'agent_created',
  CreatorDraftKind.aiNews => 'reality_fact_and_agentverse_satire',
  CreatorDraftKind.column || CreatorDraftKind.novel => 'author_created',
  CreatorDraftKind.illustratedPost => 'ai_assisted_original',
  CreatorDraftKind.selfieVideo => 'agent_created',
};

String creatorGenerationDisclosureFor(CreatorDraftKind kind) => switch (kind) {
  CreatorDraftKind.aiNews => 'ai_generated_verify_sources',
  CreatorDraftKind.selfieVideo => 'agent_directed_owner_review_required',
  _ => 'ai_assisted_owner_review_required',
};

void _validateEditorialContract({
  required CreatorDraftKind kind,
  required List<CreatorDraftBlock> blocks,
  required String disclosure,
  required String generationDisclosure,
  required List<CreatorDraftSource> sources,
  required CreatorDraftFactLayer? factLayer,
  required CreatorDraftAgentverseLayer? agentverseLayer,
}) {
  if (disclosure != creatorDisclosureFor(kind) ||
      generationDisclosure != creatorGenerationDisclosureFor(kind)) {
    throw const FormatException('Creator disclosure does not match its kind');
  }
  if (sources.map((source) => source.sourceId).toSet().length !=
      sources.length) {
    throw const FormatException('Creator sources must be unique');
  }
  if (kind == CreatorDraftKind.selfieVideo) {
    if (blocks.isNotEmpty ||
        sources.isNotEmpty ||
        factLayer != null ||
        agentverseLayer != null) {
      throw const FormatException(
        'Selfie drafts cannot contain editorial data',
      );
    }
    return;
  }
  if (kind == CreatorDraftKind.aiNews) {
    if (blocks.isNotEmpty ||
        sources.isEmpty ||
        factLayer == null ||
        agentverseLayer == null) {
      throw const FormatException(
        'AI news must separate sourced facts and Agentverse interpretation',
      );
    }
    final available = sources.map((source) => source.sourceId).toSet();
    final referenced = factLayer.sourceIds.toSet();
    if (referenced.length != factLayer.sourceIds.length ||
        available.length != referenced.length ||
        !available.containsAll(referenced) ||
        !referenced.containsAll(available)) {
      throw const FormatException('AI news fact sources are invalid');
    }
    return;
  }
  if (blocks.isEmpty || factLayer != null || agentverseLayer != null) {
    throw const FormatException('Creator editorial draft is incomplete');
  }
}

int _int(Object? value) => value is int && value > 0 ? value : 0;

String? _optionalText(Object? value, int maximumLength) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  if (text.length > maximumLength) {
    throw const FormatException('Creator text exceeds its limit');
  }
  return text;
}

void _requireOnly(Map<String, Object?> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Creator payload has unsupported fields');
  }
}

Uri _publicHttpsUri(Object? value) {
  final raw = value?.toString().trim() ?? '';
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      raw.length > 2048 ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.hasPort && uri.port != 443)) {
    throw const FormatException('Creator source URL is invalid');
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.lan') ||
      host.endsWith('.home.arpa') ||
      RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(host) ||
      host.contains(':') ||
      host.split('.').length < 2) {
    throw const FormatException('Creator source host is not public');
  }
  return uri;
}
