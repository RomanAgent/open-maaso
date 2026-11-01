import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_authoring_theme.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_service.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';

final class CompanionActivitySurfaceBundle {
  const CompanionActivitySurfaceBundle({
    required this.project,
    required this.widget,
  });

  final SurfaceProject project;
  final AgentWidget widget;
}

/// Builds a static, offline snapshot of Companion Activity state.
///
/// The project contains no network dependency, iframe, remote asset, storage
/// API, or physical reward. It is intentionally read-only; mutations continue
/// through [CompanionActivityService] and its account/generation fences.
final class CompanionActivitySurfaceFactory {
  const CompanionActivitySurfaceFactory();

  static const int maxVisibleTasks = 24;

  CompanionActivitySurfaceBundle build({
    required CompanionActivitySnapshot snapshot,
    required ActivityStreakSnapshot streak,
    required String accountId,
    required int facadeGeneration,
    required String agentId,
    required DateTime generatedAt,
  }) {
    final normalizedAccount = _bounded(accountId, 'accountId', 256);
    final normalizedAgent = _bounded(agentId, 'agentId', 256);
    if (facadeGeneration < 1) {
      throw ArgumentError.value(facadeGeneration, 'facadeGeneration');
    }
    final projectId =
        'companion-activity-${sha256.convert(utf8.encode('$normalizedAccount|$facadeGeneration')).toString().substring(0, 20)}';
    final tasks = snapshot.tasks.toList(growable: false)
      ..sort((left, right) => right.availableAt.compareTo(left.availableAt));
    final visible = tasks.take(maxVisibleTasks).toList(growable: false);
    final completed = snapshot.tasks
        .where((task) => task.state == ActivityTaskState.completed)
        .length;
    final available = snapshot.tasks
        .where((task) => task.state == ActivityTaskState.available)
        .length;
    final pending = snapshot.tasks
        .where((task) => task.state == ActivityTaskState.evidenceSubmitted)
        .length;
    final html = _html(
      balance: snapshot.ledger.balance,
      streak: streak.current,
      longestStreak: streak.longest,
      completed: completed,
      available: available,
      pending: pending,
      tasks: visible,
    );
    final project = SurfaceProject(
      id: projectId,
      title: 'Companion Activities',
      kind: SurfaceKind.card,
      rendering: SurfaceRendering.dom,
      html: html,
      css: '${SurfaceAuthoringTheme.cssSnapshot()}\n$_css',
      js: '',
      transparent: false,
      placement: const SurfacePlacement(
        x: 0.06,
        y: 0.08,
        width: 0.88,
        height: 0.8,
      ),
      manifest: SurfaceManifest.v2(
        instructions:
            'Read-only offline Companion Activity snapshot. Do not claim physical rewards.',
      ),
      backend: const <String, Object?>{
        'schemaVersion': 1,
        'mode': 'offline_snapshot',
        'rewardFulfillment': 'virtualOnly',
      },
      revisions: const <SurfaceRevision>[],
    );
    final widget = AgentWidget(
      agentId: normalizedAgent,
      title: project.title,
      subtitle: 'Streak ${streak.current} · ${snapshot.ledger.balance} points',
      icon: '🌱',
      kind: 'surface',
      spec: projectSpec(project),
      createdAt: generatedAt.toUtc(),
    );
    return CompanionActivitySurfaceBundle(project: project, widget: widget);
  }

  Map<String, Object?> projectSpec(SurfaceProject project) => <String, Object?>{
    'surfaceId': project.id,
    'surfaceKind': project.kind.name,
    'experienceType': project.experienceType.name,
    'html': project.html,
    'css': project.css,
    'js': project.js,
    'manifest': project.manifest.toJson(),
    'backend': project.backend,
    'placement': project.placement.toJson(),
    'transparent': project.transparent,
    'rendering': project.rendering.name,
    'revisions': project.revisions
        .map((revision) => revision.toJson())
        .toList(growable: false),
  };

  SurfaceProject projectFromWidget(AgentWidget widget) {
    if (!widget.isSurface) {
      throw ArgumentError.value(widget.kind, 'widget.kind');
    }
    final json = Map<String, Object?>.from(widget.spec);
    json['id'] = (json['surfaceId'] ?? '').toString();
    json['title'] = widget.title;
    json['kind'] = json['surfaceKind'];
    final project = SurfaceProject.fromJson(json);
    final issues = SurfaceProjectValidator.diagnoseForShow(project);
    if (issues.isNotEmpty) {
      throw StateError('companion_activity_surface_invalid');
    }
    return project;
  }

  static String _html({
    required int balance,
    required int streak,
    required int longestStreak,
    required int completed,
    required int available,
    required int pending,
    required List<ActivityTask> tasks,
  }) {
    final rows = tasks.isEmpty
        ? '<p class="empty">No activities yet. Create a daily activity to begin.</p>'
        : tasks.map(_taskRow).join();
    return '''
<main class="activity-shell" data-surface-root="companion-activity">
  <header>
    <div>
      <p class="eyebrow">TOGETHER, ONE DAY AT A TIME</p>
      <h1>Companion Activities</h1>
      <p class="lede">A private, offline snapshot of your shared progress.</p>
    </div>
    <div class="points" aria-label="$balance virtual points">
      <strong>$balance</strong><span>virtual points</span>
    </div>
  </header>
  <section class="metrics" aria-label="Activity summary">
    <article><strong>$streak</strong><span>current streak</span></article>
    <article><strong>$longestStreak</strong><span>longest streak</span></article>
    <article><strong>$completed</strong><span>completed</span></article>
    <article><strong>$available</strong><span>available</span></article>
    <article><strong>$pending</strong><span>awaiting review</span></article>
  </section>
  <section class="task-section">
    <div class="section-heading">
      <h2>Recent activities</h2>
      <span>Virtual rewards only</span>
    </div>
    <div class="task-list">$rows</div>
  </section>
</main>
''';
  }

  static String _taskRow(ActivityTask task) {
    final state = switch (task.state) {
      ActivityTaskState.available => 'Ready',
      ActivityTaskState.evidenceSubmitted => 'In review',
      ActivityTaskState.completed => 'Completed',
      ActivityTaskState.expired => 'Expired',
    };
    final date = task.availableAt.toUtc().toIso8601String().substring(0, 10);
    return '''
<article class="task task-${task.state.name}">
  <div><h3>${_escape(task.title)}</h3><p>$date · ${task.cadence.name}</p></div>
  <div class="task-meta"><span class="state">$state</span><strong>+${task.awardPoints}</strong></div>
</article>
''';
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static String _bounded(String value, String field, int maximumLength) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > maximumLength) {
      throw ArgumentError.value(value, field);
    }
    return normalized;
  }

  static const String _css = '''
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:var(--maaso-canvas)}
.activity-shell{max-width:920px;margin:0 auto;padding:32px}
header{display:flex;align-items:flex-start;justify-content:space-between;gap:24px;padding:24px;border:0;border-radius:var(--maaso-radius-card);background:var(--maaso-muted)}
.eyebrow{margin:0 0 8px;color:var(--maaso-accent);font-size:11px;font-weight:600;letter-spacing:.12em}
h1{margin:0;font-size:28px;line-height:1.3}.lede{margin:12px 0 0;color:var(--maaso-text-secondary);font-size:15px}
.points{min-width:128px;padding:16px;border-radius:var(--maaso-radius-input);text-align:center;background:var(--maaso-action);color:var(--maaso-on-action)}
.points strong{display:block;font-size:28px}.points span{display:block;margin-top:4px;font-size:13px}
.metrics{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;margin:16px 0}
.metrics article{padding:16px;border:0;border-radius:var(--maaso-radius-compact);background:var(--maaso-muted)}
.metrics strong{display:block;font-size:24px}.metrics span{display:block;margin-top:4px;color:var(--maaso-text-secondary);font-size:13px}
.task-section{padding:24px;border:0;border-radius:var(--maaso-radius-card);background:var(--maaso-surface)}
.section-heading{display:flex;align-items:center;justify-content:space-between;gap:16px}.section-heading h2{margin:0;font-size:20px}.section-heading span{color:var(--maaso-accent);font-size:13px}
.task-list{display:grid;gap:8px;margin-top:16px}.task{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px;border-radius:var(--maaso-radius-compact);background:var(--maaso-muted);border:0}
.task h3{margin:0;font-size:15px;overflow-wrap:anywhere}.task p{margin:4px 0 0;color:var(--maaso-text-secondary);font-size:13px}.task-meta{display:flex;align-items:center;gap:12px}.task-meta strong{color:var(--maaso-accent)}.state{padding:4px 12px;border:0;border-radius:var(--maaso-radius-pill);background:var(--maaso-capsule-fill);color:var(--maaso-accent);font-size:13px}.task-completed .state{color:var(--maaso-success)}.task-expired .state{color:var(--maaso-text-secondary)}.empty{margin:24px 0 4px;color:var(--maaso-text-secondary)}
@media(max-width:700px){.activity-shell{padding:16px}header{display:block}.points{margin-top:16px}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.task{align-items:flex-start}.task-meta{display:grid;justify-items:end}.section-heading{align-items:flex-start;flex-wrap:wrap}}
''';
}
