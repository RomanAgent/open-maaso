import 'dart:async';
import 'package:flutter/foundation.dart';
import '../domain/content_review.dart';

/// Owns only the review projection and an unsent appeal draft. Public writes
/// require the user's submit button; an Agent can only prepare that draft.
class ContentReviewController extends ChangeNotifier {
  ContentReviewController(this.gateway) : _scope = gateway.contextKey {
    _changes = gateway.reviewChanges.listen((_) => _retireIfChanged());
  }
  final ContentReviewGateway gateway;
  final String _scope;
  late final StreamSubscription<void> _changes;
  List<ContentReview> _items = const [];
  final Set<String> _appealed = {};
  bool _disposed = false;
  bool _loading = false;
  bool _submitting = false;
  String? _error;
  String? _selected;
  String _draft = '';
  bool userControl = false;

  bool get active =>
      !_disposed && gateway.reviewActive && gateway.contextKey == _scope;
  List<ContentReview> get items => active ? _items : const [];
  bool get loading => active && _loading;
  bool get submitting => active && _submitting;
  String? get error => active ? _error : null;
  String? get selected => active ? _selected : null;
  String get draft => active ? _draft : '';
  bool appealed(String id) {
    if (!active) return false;
    final review = _items.where((r) => r.id == id).firstOrNull;
    return review != null &&
        (review.appealState != null ||
            _appealed.contains('$id:${review.version}'));
  }

  bool get canSubmit =>
      active &&
      !_submitting &&
      _selected != null &&
      !appealed(_selected!) &&
      _draft.trim().isNotEmpty &&
      _draft.trim().runes.length <= 600;

  Future<bool> refresh() async {
    if (!active || _loading || _submitting) return false;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final rows = await gateway.reviews();
      if (!active) return false;
      _items = List.unmodifiable(rows);
      if (!_items.any(
        (r) =>
            r.id == _selected &&
            r.state == ContentReviewState.rejected &&
            !appealed(r.id),
      )) {
        _selected = null;
        _draft = '';
      }
      return true;
    } catch (_) {
      if (active) _error = 'load';
      return false;
    } finally {
      if (active) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  bool prepare(String reviewId, String reason, {bool fromAgent = false}) {
    final body = reason.trim();
    if (!active ||
        _submitting ||
        (fromAgent && userControl) ||
        body.runes.length > 600 ||
        appealed(reviewId) ||
        !_items.any(
          (r) => r.id == reviewId && r.state == ContentReviewState.rejected,
        )) {
      return false;
    }
    _selected = reviewId;
    _draft = body;
    _error = null;
    notifyListeners();
    return true;
  }

  void edit(String reason) {
    if (!active || _submitting || _selected == null) return;
    _draft = reason;
    notifyListeners();
  }

  Future<bool> submitByUser() async {
    if (!canSubmit) return false;
    final review = _items
        .where(
          (r) =>
              r.id == _selected &&
              r.state == ContentReviewState.rejected &&
              !appealed(r.id),
        )
        .firstOrNull;
    if (review == null) return false;
    _submitting = true;
    _error = null;
    notifyListeners();
    try {
      await gateway.appealReview(review, _draft.trim());
      if (!active) return false;
      _appealed.add('${review.id}:${review.version}');
      _selected = null;
      _draft = '';
      return true;
    } catch (_) {
      if (active) _error = 'appeal';
      return false;
    } finally {
      if (active) {
        _submitting = false;
        notifyListeners();
      }
    }
  }

  void _retireIfChanged() {
    if (_disposed || active) return;
    _items = const [];
    _appealed.clear();
    _selected = null;
    _draft = '';
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_changes.cancel());
    _items = const [];
    _appealed.clear();
    _draft = '';
    super.dispose();
  }
}
