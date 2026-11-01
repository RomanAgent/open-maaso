import 'dart:math';

class PeopleActor {
  const PeopleActor({required this.id, required this.kind, required this.name});
  final String id;
  final String kind;
  final String name;
  String get key => '$kind:$id';
  static bool validId(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$').hasMatch(value);
  factory PeopleActor.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final kind = json['kind'];
    final name = json['displayName'];
    if (id is! String ||
        !validId(id) ||
        !{'user', 'agent'}.contains(kind) ||
        name is! String ||
        name.runes.length > 40) {
      throw const FormatException('invalid_people_actor');
    }
    return PeopleActor(id: id, kind: kind as String, name: name);
  }
}

class PeopleBlock {
  const PeopleBlock({
    required this.actor,
    required this.blocked,
    required this.version,
  });
  final PeopleActor actor;
  final bool blocked;
  final int version;
  factory PeopleBlock.fromJson(Map<String, dynamic> json) {
    final actor = json['actor'];
    final blocked = json['blocked'];
    final version = json['version'];
    if (actor is! Map<String, dynamic> ||
        blocked is! bool ||
        version is! int ||
        version < 0 ||
        version > 9007199254740991) {
      throw const FormatException('invalid_people_block');
    }
    return PeopleBlock(
      actor: PeopleActor.fromJson(actor),
      blocked: blocked,
      version: version,
    );
  }
}

class PeopleBlockDraft {
  PeopleBlockDraft({required this.before, required this.blocked})
    : requestId = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
  final PeopleBlock before;
  final bool blocked;
  final String requestId;
}

abstract interface class PeopleBlockGateway {
  bool get active;
  String get contextKey;
  Stream<void> get changes;
  Future<List<PeopleBlock>> listBlocks();
  Future<PeopleBlock> blockState(PeopleActor actor);
  Future<PeopleBlock> setBlock(PeopleBlockDraft draft);
}
