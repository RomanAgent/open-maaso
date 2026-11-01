import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'surface_bundle_presentation.dart';
import 'surface_agent_document.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';

enum SurfaceKind {
  card,
  fullscreen,
  floatingCanvas,
  transparentOverlay,
  background,
}

enum SurfaceRendering {
  dom,
  canvas,
  svg,
  three,
  pixi,
  hybrid,
  webApp,
  workerCanvas,
  projectBundle,
}

enum SurfaceExperienceType { utility, game }

class SurfacePlacement {
  const SurfacePlacement({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  factory SurfacePlacement.fromJson(Object? raw) {
    if (raw is! Map) {
      return const SurfacePlacement(x: 0, y: 0, width: 1, height: 1);
    }
    return SurfacePlacement(
      x: _asDouble(raw['x'], 0),
      y: _asDouble(raw['y'], 0),
      width: _asDouble(raw['width'], 1),
      height: _asDouble(raw['height'], 1),
    );
  }

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  static double _asDouble(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

class SurfaceRevision {
  const SurfaceRevision({
    required this.id,
    required this.html,
    required this.css,
    required this.js,
    this.title,
    this.surfaceKind,
    this.rendering,
    this.transparent,
    this.placement,
    this.experienceType,
    this.category,
    this.skillInstructions,
    this.manifest,
    this.backend,
    this.note = '',
    this.createdAtMillis = 0,
  });

  final String id;
  final String html;
  final String css;
  final String js;
  final String? title;
  final String? surfaceKind;
  final String? rendering;
  final bool? transparent;
  final Map<String, Object?>? placement;
  final String? experienceType;
  final String? category;
  final String? skillInstructions;
  final Map<String, Object?>? manifest;
  final Map<String, Object?>? backend;
  final String note;
  final int createdAtMillis;

  factory SurfaceRevision.fromJson(Object? raw) {
    if (raw is! Map) {
      return const SurfaceRevision(id: '', html: '', css: '', js: '');
    }
    return SurfaceRevision(
      id: (raw['id'] ?? '').toString(),
      html: (raw['html'] ?? '').toString(),
      css: (raw['css'] ?? '').toString(),
      js: (raw['js'] ?? '').toString(),
      title: raw['title']?.toString(),
      surfaceKind: (raw['surfaceKind'] ?? raw['kind'])?.toString(),
      rendering: raw['rendering']?.toString(),
      transparent: raw['transparent'] as bool?,
      placement: raw['placement'] == null
          ? null
          : _stringKeyedMap(raw['placement']),
      experienceType: raw['experienceType']?.toString(),
      category: raw['category']?.toString(),
      skillInstructions: raw['skillInstructions']?.toString(),
      manifest: raw['manifest'] == null
          ? null
          : _stringKeyedMap(raw['manifest']),
      backend: raw['backend'] == null ? null : _stringKeyedMap(raw['backend']),
      note: (raw['note'] ?? '').toString(),
      createdAtMillis:
          (raw['createdAtMillis'] as num?)?.toInt() ??
          DateTime.tryParse(
            raw['createdAt']?.toString() ?? '',
          )?.millisecondsSinceEpoch ??
          0,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'html': html,
    'css': css,
    'js': js,
    if (title != null) 'title': title,
    if (surfaceKind != null) 'surfaceKind': surfaceKind,
    if (rendering != null) 'rendering': rendering,
    if (transparent != null) 'transparent': transparent,
    if (placement != null) 'placement': placement,
    if (experienceType != null) 'experienceType': experienceType,
    if (category != null) 'category': category,
    if (skillInstructions != null) 'skillInstructions': skillInstructions,
    if (manifest != null) 'manifest': manifest,
    if (backend != null) 'backend': backend,
    if (note.isNotEmpty) 'note': note,
    if (createdAtMillis > 0) 'createdAtMillis': createdAtMillis,
  };

  static Map<String, Object?> _stringKeyedMap(Object? raw) {
    if (raw is! Map) return <String, Object?>{};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
}

class SurfaceProject {
  SurfaceProject({
    required this.id,
    required this.title,
    required this.kind,
    required this.rendering,
    required this.html,
    required this.css,
    required this.js,
    required this.transparent,
    required this.placement,
    required this.manifest,
    required this.backend,
    required this.revisions,
    this.experienceType = SurfaceExperienceType.utility,
    this.category = 'tools',
    this.skillInstructions = '',
    this.versionHistory,
    this.bundlePresentation,
  });

  final String id;
  final String title;
  final SurfaceKind kind;
  final SurfaceRendering rendering;
  final String html;
  final String css;
  final String js;
  final bool transparent;
  final SurfacePlacement placement;
  final SurfaceManifest manifest;
  final Map<String, Object?> backend;
  final List<SurfaceRevision> revisions;
  final SurfaceExperienceType experienceType;
  final String category;
  final String skillInstructions;
  final SurfaceVersionHistory? versionHistory;
  final SurfaceBundlePresentation? bundlePresentation;

  factory SurfaceProject.fromJson(Map<dynamic, dynamic> json) {
    if (json['rendering'] == 'projectBundle' ||
        json.containsKey('bundleReference')) {
      throw const FormatException('bundle_requires_verified_installation');
    }
    return SurfaceProject(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      kind: _parseKind(json['kind']),
      rendering: _parseRendering(json['rendering']),
      html: (json['html'] ?? '').toString(),
      css: (json['css'] ?? '').toString(),
      js: (json['js'] ?? '').toString(),
      transparent: json['transparent'] == true,
      placement: SurfacePlacement.fromJson(json['placement']),
      manifest: SurfaceManifest.fromSpec(json['manifest']),
      backend: _stringKeyedMap(json['backend']),
      revisions: _parseRevisions(json['revisions']),
      experienceType: _parseExperienceType(json['experienceType']),
      category: _parseCategory(json['category'], json['experienceType']),
      skillInstructions: _boundedInstructions(json['skillInstructions']),
      versionHistory: json['versionHistory'] == null
          ? null
          : SurfaceVersionHistory.read(
              json.map((key, value) => MapEntry(key.toString(), value)),
              title: (json['title'] ?? '').toString(),
            ),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'kind': kind.name,
    'rendering': rendering.name,
    'html': html,
    'css': css,
    'js': js,
    'transparent': transparent,
    'placement': placement.toJson(),
    'manifest': manifest.toJson(),
    'backend': backend,
    'revisions': revisions.map((revision) => revision.toJson()).toList(),
    'experienceType': experienceType.name,
    'category': category,
    'skillInstructions': skillInstructions,
    if (bundlePresentation case final presentation?
        when presentation.permit is VerifiedProjectBundlePermit)
      'bundleReference': {
        'packageSchema': 2,
        'projectId': presentation.installed.bundle.manifest.projectId,
        'revisionId': presentation.installed.bundle.manifest.revisionId,
        'candidateDigest': presentation.installed.candidateDigest,
        'reportDigest':
            (presentation.permit as VerifiedProjectBundlePermit).reportDigest,
      },
    if (versionHistory != null) 'versionHistory': versionHistory!.toJson(),
  };

  static String _parseCategory(Object? raw, Object? experienceType) {
    final value = raw?.toString().trim() ?? '';
    if (const {'travel', 'tools', 'game'}.contains(value)) return value;
    return experienceType == 'game' ? 'game' : 'tools';
  }

  static String _boundedInstructions(Object? raw) {
    return readSurfaceAgentDocument(raw);
  }

  static SurfaceKind _parseKind(Object? raw) {
    final name = raw?.toString();
    for (final kind in SurfaceKind.values) {
      if (kind.name == name) return kind;
    }
    return SurfaceKind.card;
  }

  static SurfaceRendering _parseRendering(Object? raw) {
    final name = raw?.toString();
    for (final rendering in SurfaceRendering.values) {
      if (rendering.name == name) return rendering;
    }
    return SurfaceRendering.dom;
  }

  static SurfaceExperienceType _parseExperienceType(Object? raw) {
    final name = raw?.toString();
    for (final experienceType in SurfaceExperienceType.values) {
      if (experienceType.name == name) return experienceType;
    }
    return SurfaceExperienceType.utility;
  }

  static Map<String, Object?> _stringKeyedMap(Object? raw) {
    if (raw is! Map) return <String, Object?>{};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static List<SurfaceRevision> _parseRevisions(Object? raw) {
    if (raw is! List) return const <SurfaceRevision>[];
    return raw.map(SurfaceRevision.fromJson).toList();
  }
}

/// Whether presenting [project] must reach a real first frame before its
/// pending persistence transaction can be committed.
///
/// `workerCanvas` keeps its existing declarative-runtime health check. The
/// private `webApp` renderer runs ordinary Web content, so its admission check
/// is intentionally limited to the host-observed first-frame lifecycle.
bool surfaceRequiresFirstFrameValidation(SurfaceProject project) {
  return project.rendering == SurfaceRendering.workerCanvas ||
      project.rendering == SurfaceRendering.webApp;
}
