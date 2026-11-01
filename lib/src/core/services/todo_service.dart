import 'package:maaso/src/core/foundation/app_framework.dart';

/// One item in the agent's working checklist.
class TodoItem {
  final String id;
  String text;
  bool done;
  final DateTime createdAt;
  DateTime? doneAt;

  TodoItem({
    required this.id,
    required this.text,
    this.done = false,
    DateTime? createdAt,
    this.doneAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'done': done,
    'createdAt': createdAt.toIso8601String(),
    if (doneAt != null) 'doneAt': doneAt!.toIso8601String(),
  };
}

/// Working memory for an in-flight task — the agent uses [TodoSkill] to
/// add/check off items, the home page renders the list as a corner
/// checklist so the user can see what the agent is doing.
///
/// Cleared automatically when [clear] is called, or when a new chat turn
/// starts with no prior items.  Persisted only in memory (todos are about
/// "right now", not history).
class TodoService extends AppService {
  final RxList<TodoItem> items = <TodoItem>[].obs;

  int _seq = 0;

  String add(String text) {
    final id = 't${++_seq}';
    items.add(TodoItem(id: id, text: text));
    return id;
  }

  bool complete(String id) {
    final i = items.indexWhere((t) => t.id == id);
    if (i < 0) return false;
    if (items[i].done) return true;
    items[i].done = true;
    items[i].doneAt = DateTime.now();
    items.refresh();
    return true;
  }

  void clear() {
    items.clear();
    _seq = 0;
  }

  List<Map<String, dynamic>> snapshot() =>
      items.map((t) => t.toJson()).toList();

  int get pendingCount => items.where((t) => !t.done).length;
}
