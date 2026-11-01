import 'package:maaso/src/core/foundation/app_framework.dart';

import 'persistence/account_storage_scope_service.dart';
import 'persistence/markdown_document_store.dart';

/// Stores the agent's "soul" — the things that make this particular instance
/// *this* agent rather than a generic LLM persona — in a `soul.md` file under
/// the app's documents directory.
///
/// Layout is a tiny YAML-ish frontmatter (so the LLM can be taught to write
/// it back via [SetSoulSkill]) followed by a free-form Notes section the
/// agent can extend over time:
///
/// ```markdown
/// # Agent Soul
///
/// - name: Hiyori
/// - age: 18
/// - gender: female
///
/// ## Notes
/// (free-form lines the agent appends as it learns about its master)
/// ```
///
/// The file is the single source of truth.  `name`/`age`/`gender` populate
/// the system prompt and, separately, sync into [AgentProfile.nickname] so
/// the existing UI (chat header, avatar label) keeps working.
class SoulService extends AppService {
  // ─────────────────── Reactive fields ───────────────────
  final RxnString name = RxnString();
  final RxnInt age = RxnInt();
  final RxnString gender = RxnString();
  final RxBool genderLocked = false.obs;
  final RxString notes = ''.obs;

  /// True once at least [name], [age] and [gender] have all been filled in.
  /// HomeController uses this to decide whether to fire the bootstrap
  /// "first meeting" interview turn.
  bool get configured =>
      (name.value?.trim().isNotEmpty ?? false) &&
      age.value != null &&
      (gender.value?.trim().isNotEmpty ?? false);

  late MarkdownDocumentStore _document;

  Future<SoulService> init({AgentStorageScope? scope}) async {
    _document = scope == null
        ? await openMarkdownDocumentStore('soul.md')
        : await openAgentMarkdownDocumentStore(
            scope,
            AgentMarkdownDocumentKind.soul,
          );
    final markdown = await _document.read();
    if (markdown != null) _parse(markdown);
    if ((gender.value ?? '').trim().isNotEmpty) genderLocked.value = true;
    return this;
  }

  /// Update one or more fields; missing keys are left as-is.  Writes through
  /// to `soul.md` immediately so a crash mid-session doesn't lose what the
  /// agent learned this turn.
  Future<void> update({
    String? name,
    int? age,
    String? gender,
    String? notesAppend,
    String? notesReplace,
  }) async {
    if (name != null && name.trim().isNotEmpty) this.name.value = name.trim();
    if (age != null) this.age.value = age;
    if (gender != null && gender.trim().isNotEmpty && !genderLocked.value) {
      this.gender.value = gender.trim();
    }
    if (notesReplace != null) {
      notes.value = notesReplace.trim();
    } else if (notesAppend != null && notesAppend.trim().isNotEmpty) {
      final extra = notesAppend.trim();
      notes.value = notes.value.isEmpty ? extra : '${notes.value}\n$extra';
    }
    await _document.write(toMarkdown());
  }

  void lockGender() {
    genderLocked.value = true;
  }

  /// Host projection of a human's explicit, account-synchronized setup choice.
  /// This is not exposed as an Agent skill: ordinary [update] calls continue
  /// to respect the gender lock. Notes, name and locally learned memory stay.
  Future<void> applyCompanionSetupGender(String value) async {
    if (!const {'female', 'male', 'nonbinary'}.contains(value)) {
      throw const FormatException('invalid_companion_gender');
    }
    if (gender.value == value && genderLocked.value) return;
    final previousGender = gender.value;
    final previousLock = genderLocked.value;
    gender.value = value;
    genderLocked.value = true;
    try {
      await _document.write(toMarkdown());
    } catch (_) {
      gender.value = previousGender;
      genderLocked.value = previousLock;
      rethrow;
    }
  }

  String toMarkdown() {
    final buf = StringBuffer()
      ..writeln('# Agent Soul')
      ..writeln()
      ..writeln('- name: ${name.value ?? ""}')
      ..writeln('- age: ${age.value ?? ""}')
      ..writeln('- gender: ${gender.value ?? ""}')
      ..writeln()
      ..writeln('## Notes');
    if (notes.value.trim().isEmpty) {
      buf.writeln('(empty)');
    } else {
      buf.writeln(notes.value.trim());
    }
    return buf.toString();
  }

  // ────────────────────── Parser ──────────────────────
  // Forgiving line-based parser: looks for `- key: value` pairs in the
  // header, treats everything after `## Notes` as the notes body.

  static final _kv = RegExp(r'^-\s*([A-Za-z_]+)\s*:\s*(.*)\s*$');

  void _parse(String md) {
    var inNotes = false;
    final notesBuf = StringBuffer();
    for (final raw in md.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().toLowerCase().startsWith('## notes')) {
        inNotes = true;
        continue;
      }
      if (inNotes) {
        notesBuf.writeln(line);
        continue;
      }
      final m = _kv.firstMatch(line);
      if (m == null) continue;
      final key = m.group(1)!.toLowerCase();
      final value = m.group(2)!.trim();
      if (value.isEmpty) continue;
      switch (key) {
        case 'name':
          name.value = value;
          break;
        case 'age':
          final parsed = int.tryParse(value);
          if (parsed != null) age.value = parsed;
          break;
        case 'gender':
          gender.value = value;
          break;
      }
    }
    final body = notesBuf.toString().trim();
    if (body.isNotEmpty && body.toLowerCase() != '(empty)') {
      notes.value = body;
    }
  }
}
