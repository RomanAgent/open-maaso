import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sembast/sembast.dart';

import 'package:maaso/src/core/models/learned_skill.dart';
import 'package:maaso/src/core/services/db_service.dart';

/// Persists and serves the agent's *learned* skills — runtime-defined
/// macros (sequences of JS calls with optional delays) the agent acquires
/// by being taught, either by the user or, in the future, by a peer agent.
///
/// Storage: sembast store keyed by skill id.  Cheap to load all at boot
/// (typical user has a handful, not thousands).  In-memory mirror is an
/// [RxList] so the UI / system prompt can react to changes immediately.
class LearnedSkillService extends AppService {
  final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('learned_skills');

  final RxList<LearnedSkill> skills = <LearnedSkill>[].obs;

  Database get _db => appServices.find<DBService>().raw;

  Future<LearnedSkillService> init() async {
    final records = await _store.find(_db);
    skills.assignAll(records.map((r) => LearnedSkill.fromJson(r.value)));
    return this;
  }

  Future<LearnedSkill> add(LearnedSkill s) async {
    await _store.record(s.id).put(_db, s.toJson());
    // Replace by id if it already exists, else append.
    final i = skills.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      skills[i] = s;
    } else {
      skills.add(s);
    }
    return s;
  }

  Future<bool> remove(String id) async {
    await _store.record(id).delete(_db);
    final i = skills.indexWhere((x) => x.id == id);
    if (i < 0) return false;
    skills.removeAt(i);
    return true;
  }

  LearnedSkill? byId(String id) {
    for (final s in skills) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Match by exact id, or by exact name, or by case-insensitive name —
  /// the LLM is sloppy about which it remembers.
  LearnedSkill? resolve(String key) {
    final exact = byId(key);
    if (exact != null) return exact;
    for (final s in skills) {
      if (s.name == key) return s;
    }
    final lower = key.toLowerCase();
    for (final s in skills) {
      if (s.name.toLowerCase() == lower) return s;
      if (s.id.toLowerCase() == lower) return s;
    }
    return null;
  }

  Future<void> bumpUseCount(String id) async {
    final s = byId(id);
    if (s == null) return;
    s.useCount += 1;
    await _store.record(s.id).put(_db, s.toJson());
    skills.refresh();
  }

  /// Generate a stable id from a name.  ASCII fallback when the name is
  /// pure CJK; otherwise a slug.  Collisions get a numeric suffix.
  String generateId(String name) {
    final ascii = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    String base = ascii.isEmpty
        ? 'sk_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        : ascii;
    if (base.length > 40) base = base.substring(0, 40);
    if (byId(base) == null) return base;
    int n = 2;
    while (byId('${base}_$n') != null) {
      n++;
    }
    return '${base}_$n';
  }
}
