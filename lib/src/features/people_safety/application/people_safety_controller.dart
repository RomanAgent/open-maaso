import 'dart:async';
import 'package:flutter/foundation.dart';
import '../domain/people_block.dart';

class PeopleSafetyController extends ChangeNotifier {
  PeopleSafetyController(this.gateway) : _key = gateway.contextKey {
    _subscription = gateway.changes.listen((_) {
      if (!active) {
        items = const [];
        draft = null;
      }
      notifyListeners();
    });
  }
  final PeopleBlockGateway gateway;
  final String _key;
  late final StreamSubscription<void> _subscription;
  bool _disposed = false;
  bool busy = false;
  bool userControl = false;
  String? error;
  List<PeopleBlock> items = const [];
  PeopleBlockDraft? draft;
  bool get active => !_disposed && gateway.active && gateway.contextKey == _key;
  Future<bool> refresh() async {
    if (!active || busy) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final rows = await gateway.listBlocks();
      if (!active) return false;
      items = List.unmodifiable(rows.where((row) => row.blocked));
      return true;
    } catch (_) {
      if (active) error = 'load_failed';
      return false;
    } finally {
      if (active) {
        busy = false;
        notifyListeners();
      }
    }
  }

  bool prepareUnblock(String actorId, String kind, {bool fromAgent = false}) {
    if (!active || busy || fromAgent && userControl || draft != null) {
      return false;
    }
    final found = items.where(
      (row) => row.actor.id == actorId && row.actor.kind == kind,
    );
    if (found.length != 1) return false;
    draft = PeopleBlockDraft(before: found.single, blocked: false);
    error = null;
    notifyListeners();
    return true;
  }

  void userActivity() {
    userControl = true;
  }

  void cancel() {
    if (!busy) {
      draft = null;
      error = null;
      notifyListeners();
    }
  }

  Future<bool> confirm() async {
    final selected = draft;
    if (!active || busy || selected == null) return false;
    userActivity();
    busy = true;
    error = null;
    notifyListeners();
    try {
      await gateway.setBlock(selected);
      if (!active) return false;
      items = List.unmodifiable(
        items.where((row) => row.actor.key != selected.before.actor.key),
      );
      draft = null;
      return true;
    } catch (e) {
      if (active) {
        error = e.toString().contains('409')
            ? 'state_changed'
            : 'submit_failed';
        if (error == 'state_changed') draft = null;
      }
      return false;
    } finally {
      if (active) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    items = const [];
    draft = null;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
