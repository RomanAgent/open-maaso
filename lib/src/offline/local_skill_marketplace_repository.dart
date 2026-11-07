import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

/// Account-database implementation behind the original Skill Store contract.
/// Only declarative prompt content is imported; packages never execute code.
class LocalSkillMarketplaceRepository {
  LocalSkillMarketplaceRepository(this.database);
  final DBService database;
  static final _store = StoreRef<String, Map<String, Object?>>(
    'local_skill_marketplace',
  );

  Future<Object?> request(Uri uri, String method, Map<String, dynamic>? body) =>
      database.raw.transaction((tx) async {
        final state = Map<String, Object?>.from(
          await _store.record('state').get(tx) ?? _seed(),
        );
        final result = _route(state, uri, method, body ?? {});
        await _store.record('state').put(tx, state);
        return result;
      });

  Future<MarketplaceSubmissionResult> importPackage(
    File package, {
    required SkillVisibility visibility,
    required String versionName,
  }) async {
    if (visibility == SkillVisibility.unknown) {
      throw StateError('Select a Skill visibility');
    }
    if (await package.length() > 8 * 1024 * 1024) {
      throw StateError('Local Skill package exceeds 8 MiB');
    }
    final bytes = await package.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.length > 64) throw StateError('Too many Skill package entries');
    var total = 0;
    ArchiveFile? manifest;
    for (final entry in archive) {
      total += entry.size;
      if (total > 16 * 1024 * 1024 ||
          entry.name.startsWith('/') ||
          entry.name.contains('\\') ||
          entry.name.split('/').contains('..') ||
          entry.isSymbolicLink) {
        throw StateError('Invalid local Skill package');
      }
      if (entry.name == 'manifest.json' && entry.isFile) {
        if (manifest != null || entry.size > 65536) {
          throw StateError('Invalid Skill manifest');
        }
        manifest = entry;
      }
    }
    if (manifest == null) throw StateError('Skill manifest.json is required');
    final decoded = jsonDecode(utf8.decode(manifest.content));
    if (decoded is! Map || decoded['schema'] != 'maaso.skill.v1') {
      throw StateError(
        'Local Skills require a declarative maaso.skill.v1 manifest',
      );
    }
    final map = Map<String, dynamic>.from(decoded);
    final skill = _skill(
      0,
      key: _text(map['key'], 100),
      title: _text(map['title'], 120),
      summary: _text(map['summary'], 500, required: false),
      instruction: _text(map['instruction'], 8192),
      category: _text(map['category'], 32),
      version: _text(versionName, 64),
      visibility: visibility.wireValue,
    );
    if (!const {
      'observation',
      'reasoning',
      'collaboration',
    }.contains(skill['category'])) {
      throw StateError('Unknown Skill category');
    }
    final permissions = map['permissions'];
    if (permissions is! List ||
        permissions.length > 32 ||
        permissions.any(
          (p) =>
              p is! String ||
              !const {
                'conversation.read',
                'memory.read',
                'surface.read',
              }.contains(p),
        )) {
      throw StateError('Local prompt Skills cannot grant native permissions');
    }
    skill['permissions'] = List<String>.from(permissions);
    final examples = map['examples'];
    if (examples is List) {
      skill['examples'] = examples.take(8).map((e) => _text(e, 500)).toList();
    }
    skill['manifestDigest'] = sha256.convert(bytes).toString();
    return database.raw.transaction((tx) async {
      final state = Map<String, Object?>.from(
        await _store.record('state').get(tx) ?? _seed(),
      );
      final skills = _maps(state, 'skills');
      if (skills.length >= 250) throw StateError('Local Skill limit reached');
      final id = _id(state);
      skill['skillVersionId'] = id;
      skill['submissionId'] = id;
      skills.add(skill);
      state['skills'] = skills;
      await _store.record('state').put(tx, state);
      return MarketplaceSubmissionResult.fromJson(_submission(skill));
    });
  }

  Object? _route(
    Map<String, Object?> state,
    Uri uri,
    String method,
    Map<String, dynamic> body,
  ) {
    final p = uri.pathSegments;
    final skills = _maps(state, 'skills');
    final installs = _maps(state, 'installations');
    final drafts = _maps(state, 'drafts');
    state['skills'] = skills;
    state['installations'] = installs;
    state['drafts'] = drafts;
    Map<String, Object?> findSkill(String id) => skills.firstWhere(
      (s) => s['skillVersionId'].toString() == id || s['skillKey'] == id,
      orElse: () => throw StateError('Local Skill was not found'),
    );
    if (p.length == 3 && p[0] == 'v1' && p[1] == 'skills' && method == 'GET') {
      switch (p[2]) {
        case 'catalog':
        case 'rankings':
        case 'mine':
          final query = (uri.queryParameters['query'] ?? '').toLowerCase();
          final result = skills
              .where(
                (s) =>
                    (p[2] != 'mine' || s['publisherId'] == 'local-user') &&
                    '${s['title']} ${s['summary']} ${s['skillKey']}'
                        .toLowerCase()
                        .contains(query),
              )
              .toList();
          if (p[2] == 'rankings') {
            result.sort(
              (a, b) =>
                  (b['likeCount'] as int).compareTo(a['likeCount'] as int),
            );
          }
          return result;
        case 'installations':
          return installs
              .where((i) => i['agentId'] == uri.queryParameters['agentId'])
              .toList();
        case 'drafts':
          return drafts;
        default:
          return findSkill(p[2]);
      }
    }
    if (p.length == 4 &&
        p[1] == 'skills' &&
        p[3] == 'install' &&
        method == 'POST') {
      final skill = findSkill(p[2]);
      final accepted = (body['acceptedPermissions'] as List? ?? []).toSet();
      final required = (skill['permissions'] as List).toSet();
      if (accepted.length != required.length ||
          !accepted.containsAll(required)) {
        throw StateError('Accept exactly the requested Skill permissions');
      }
      final agent = _text(body['agentId'], 256);
      final existing = installs
          .where(
            (i) =>
                i['agentId'] == agent &&
                i['skillVersionId'] == skill['skillVersionId'],
          )
          .firstOrNull;
      final installation =
          existing ??
          <String, Object?>{
            'installationId': _id(state),
            'skillVersionId': skill['skillVersionId'],
            'agentId': agent,
          };
      installation['status'] = 'active';
      if (existing == null) installs.add(installation);
      _counts(skills, installs);
      return installation;
    }
    if (p.length == 5 &&
        p[1] == 'skills' &&
        p[2] == 'installations' &&
        p[4] == 'status' &&
        method == 'POST') {
      final installation = installs.firstWhere(
        (i) => i['installationId'].toString() == p[3],
      );
      final status = body['status'];
      if (!const {'active', 'disabled', 'uninstalled'}.contains(status)) {
        throw StateError('Invalid Skill status');
      }
      installation['status'] = status;
      _counts(skills, installs);
      return installation;
    }
    if (p.length == 5 &&
        p[1] == 'skills' &&
        p[3] == 'likes' &&
        p[4] == 'status' &&
        method == 'POST') {
      final skill = findSkill(p[2]);
      skill['likedByMe'] = body['liked'] == true;
      skill['likeCount'] = body['liked'] == true ? 1 : 0;
      return skill;
    }
    if (p.length == 4 &&
        p[1] == 'skills' &&
        p[3] == 'lineage' &&
        method == 'GET') {
      final skill = findSkill(p[2]);
      final chain = <Map<String, Object?>>[];
      var current = skill;
      for (var depth = 0; depth < skills.length; depth++) {
        chain.insert(0, {
          'skill': current,
          'rootSkillVersionId':
              skill['rootSkillVersionId'] ?? skill['skillVersionId'],
          'parentSkillVersionId': current['parentSkillVersionId'],
          'lineageDepth': current['lineageDepth'] ?? 0,
          'strategy': current['instruction'],
          'isCurrent': current['skillVersionId'] == skill['skillVersionId'],
        });
        if (current['parentSkillVersionId'] == null) break;
        current = findSkill(current['parentSkillVersionId'].toString());
      }
      return chain;
    }
    if (p.length == 4 &&
        p[1] == 'skills' &&
        p[3] == 'forks' &&
        method == 'POST') {
      if (drafts.length >= 100) {
        throw StateError('Local Skill draft limit reached');
      }
      final source = findSkill(p[2]);
      final now = DateTime.now().toUtc().toIso8601String();
      final draft = <String, Object?>{
        'id': const Uuid().v4(),
        'sourceSkillVersionId': source['skillVersionId'],
        'rootSkillVersionId':
            source['rootSkillVersionId'] ?? source['skillVersionId'],
        'skillKey': source['skillKey'],
        'title': source['title'],
        'summary': source['summary'],
        'category': source['category'],
        'strategy': source['instruction'],
        'coverAssetUrl': '',
        'visibility': 'private',
        'versionName': '1.0.1',
        'status': 'draft',
        'revision': 1,
        'cases': <Map<String, Object?>>[],
        'createdAt': now,
        'updatedAt': now,
      };
      drafts.add(draft);
      return draft;
    }
    if (p.length >= 4 && p[1] == 'skills' && p[2] == 'drafts') {
      final draft = drafts.firstWhere((d) => d['id'] == p[3]);
      if (p.length == 4 && method == 'GET') return draft;
      if (draft['status'] == 'published') {
        throw StateError('Published local Skill drafts are immutable');
      }
      if (p.length == 4 && method == 'PATCH') {
        for (final field in ['title', 'summary', 'strategy', 'versionName']) {
          draft[field] = _text(
            body[field],
            field == 'strategy' ? 8192 : 500,
            required: field != 'summary',
          );
        }
        if (!const {'private', 'public'}.contains(body['visibility'])) {
          throw StateError('Invalid Skill visibility');
        }
        draft['visibility'] = body['visibility'];
        _revise(draft);
        return draft;
      }
      final cases = _maps(draft, 'cases');
      draft['cases'] = cases;
      if (p.length == 5 && p[4] == 'cases' && method == 'POST') {
        if (cases.length >= 64) {
          throw StateError('Local Skill case limit reached');
        }
        cases.add({
          'id': _id(state),
          'prompt': _text(body['prompt'], 4000),
          'expectedBehavior': _text(body['expectedBehavior'], 4000),
          'notes': _text(body['notes'], 4000, required: false),
          'sortOrder': cases.length,
        });
        _revise(draft);
        return draft;
      }
      if (p.length == 6 && p[4] == 'cases' && method == 'DELETE') {
        cases.removeWhere((c) => c['id'].toString() == p[5]);
        _revise(draft);
        return draft;
      }
      if (p.length == 5 && p[4] == 'tests' && method == 'POST') {
        // This is a local structure check, never a claimed remote/model evaluation.
        final passed =
            cases.isNotEmpty && (draft['strategy'] as String).trim().isNotEmpty;
        draft['lastTest'] = {
          'id': const Uuid().v4(),
          'draftRevision': draft['revision'],
          'status': passed ? 'passed' : 'failed',
          'totalCases': cases.length,
          'passedCases': passed ? cases.length : 0,
          'score': passed ? 100 : 0,
          'report': {
            'mode': 'local_structure_only',
            'semanticEvaluation': false,
            'message':
                'Local manifest and case structure checked. Model behavior was not evaluated.',
          },
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        };
        return draft;
      }
      if (p.length == 5 && p[4] == 'publish' && method == 'POST') {
        final test = draft['lastTest'];
        if (test is! Map ||
            test['status'] != 'passed' ||
            test['draftRevision'] != draft['revision']) {
          throw StateError(
            'Run the current local validation before saving this Skill',
          );
        }
        if (skills.length >= 250) throw StateError('Local Skill limit reached');
        final id = _id(state);
        final skill = _skill(
          id,
          key: draft['skillKey'] as String,
          title: draft['title'] as String,
          summary: draft['summary'] as String,
          instruction: draft['strategy'] as String,
          category: draft['category'] as String,
          version: draft['versionName'] as String,
          visibility: draft['visibility'] as String,
        );
        skill['rootSkillVersionId'] = draft['rootSkillVersionId'];
        skill['parentSkillVersionId'] = draft['sourceSkillVersionId'];
        skill['lineageDepth'] =
            (findSkill(draft['sourceSkillVersionId'].toString())['lineageDepth']
                    as int? ??
                0) +
            1;
        skills.add(skill);
        draft['status'] = 'published';
        draft['publishedSkillVersionId'] = id;
        return _submission(skill);
      }
    }
    if (p.length == 5 &&
        p[1] == 'agents' &&
        p[3] == 'skill-mastery' &&
        p[4] == 'events' &&
        method == 'POST') {
      final events = _maps(state, 'events');
      final eventId = _text(body['eventId'], 256);
      final key = '${p[2]}:${body['skillVersionId']}';
      if (!events.any((e) => e['eventId'] == eventId && e['agentId'] == p[2])) {
        if (events.length >= 1000) events.removeAt(0);
        events.add({'eventId': eventId, 'agentId': p[2], 'skill': key});
      }
      state['events'] = events;
      final count = events.where((e) => e['skill'] == key).length;
      return {
        'masteryBucket': count >= 30
            ? 'expert'
            : count >= 10
            ? 'confident'
            : count >= 3
            ? 'growing'
            : 'new',
      };
    }
    throw StateError(
      'This Skill operation is unavailable in the local edition',
    );
  }

  static void _revise(Map<String, Object?> draft) {
    draft['revision'] = (draft['revision'] as int) + 1;
    draft['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    draft.remove('lastTest');
  }

  static void _counts(
    List<Map<String, Object?>> skills,
    List<Map<String, Object?>> installs,
  ) {
    for (final skill in skills) {
      skill['activeInstallCount'] = installs
          .where(
            (i) =>
                i['skillVersionId'] == skill['skillVersionId'] &&
                i['status'] == 'active',
          )
          .length;
    }
  }

  static List<Map<String, Object?>> _maps(
    Map<String, Object?> state,
    String key,
  ) => [
    for (final value in state[key] is List ? state[key] as List : const [])
      if (value is Map) Map<String, Object?>.from(value),
  ];
  static int _id(Map<String, Object?> state) {
    final id = (state['nextId'] as int?) ?? 100;
    state['nextId'] = id + 1;
    return id;
  }

  static String _text(Object? value, int max, {bool required = true}) {
    if (value is! String ||
        value.length > max ||
        (required && value.trim().isEmpty)) {
      throw StateError('Invalid local Skill text');
    }
    return value.trim();
  }

  static Map<String, Object?> _submission(Map<String, Object?> skill) => {
    'submissionId': skill['submissionId'],
    'skillVersionId': skill['skillVersionId'],
    'status': 'published',
    'visibility': skill['visibility'],
    'safetyStatus': 'passed',
  };
  static Map<String, Object?> _skill(
    int id, {
    required String key,
    required String title,
    required String summary,
    required String instruction,
    required String category,
    String version = '1.0.0',
    String visibility = 'private',
  }) => {
    'skillVersionId': id,
    'submissionId': id,
    'skillKey': key,
    'title': title,
    'summary': summary,
    'coverAssetUrl': '',
    'publisherId': 'local-user',
    'versionName': version,
    'permissions': <String>[],
    'category': category,
    'instruction': instruction,
    'examples': <String>[],
    'manifestDigest': sha256
        .convert(utf8.encode('$key:$version:$instruction'))
        .toString(),
    'isFree': true,
    'visibility': visibility,
    'safetyStatus': 'passed',
    'likeCount': 0,
    'activeInstallCount': 0,
    'likedByMe': false,
  };
  static Map<String, Object?> _seed() => {
    'nextId': 100,
    'installations': <Map<String, Object?>>[],
    'drafts': <Map<String, Object?>>[],
    'events': <Map<String, Object?>>[],
    'skills': [
      _skill(
        1,
        key: 'local-plan',
        title: '任务拆解',
        summary: '把目标拆成可执行的小步骤。',
        instruction: '先确认目标和约束，再给出简短的可执行步骤。',
        category: 'reasoning',
      ),
      _skill(
        2,
        key: 'local-game-companion',
        title: '游戏陪玩',
        summary: '根据可见游戏信息提供简短陪伴。',
        instruction: '依据实际可见的游戏信息给出简短提示；无法观察时说明，不编造战况。',
        category: 'collaboration',
      ),
      _skill(
        3,
        key: 'local-review',
        title: '观察与复盘',
        summary: '区分事实与推断，再总结下一步。',
        instruction: '先列出可验证的观察，区分事实与推断，再总结下一步。',
        category: 'observation',
      ),
    ],
  };
}
