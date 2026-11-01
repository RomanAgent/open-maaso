import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_navigation.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_host.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_service.dart';

/// Root-shell Material implementation of the trusted action approval Host.
///
/// The route is pushed on the root Navigator, above account-owned page trees.
/// Its barrier cannot be dismissed, focus traversal is closed-loop, and every
/// close path is acknowledged only after the route has left the overlay.
final class MaterialActionApprovalHost implements ActionApprovalHost {
  MaterialActionApprovalHost({GlobalKey<NavigatorState>? navigatorKey})
    : _navigatorKey = navigatorKey ?? rootNavigatorKey;

  final GlobalKey<NavigatorState> _navigatorKey;
  final Set<_MaterialActionApprovalSession> _sessions =
      Set<_MaterialActionApprovalSession>.identity();
  Completer<void>? _allDismissed;

  @override
  Future<void> get whenAllDismissed =>
      _allDismissed?.future ?? Future<void>.value();

  @override
  ActionApprovalSession present(ActionApprovalPrompt prompt) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      throw StateError('The root action approval Navigator is unavailable.');
    }

    late final _MaterialActionApprovalSession session;
    final route = _ActionApprovalRoute(
      pageBuilder: (context, animation, secondaryAnimation) =>
          _ActionApprovalDialog(prompt: prompt, session: session),
      routeName: '/_system/action-approval/${prompt.fingerprint}',
      onDisposed: () => session._completeAfterRouteClosed(),
    );
    if (_sessions.isEmpty) _allDismissed = Completer<void>.sync();
    session = _MaterialActionApprovalSession(
      navigator: navigator,
      route: route,
      onClosed: _handleSessionClosed,
    );
    _sessions.add(session);
    try {
      final routeCompletion = navigator.push<void>(route);
      session._attachRouteCompletion(routeCompletion);
    } catch (_) {
      _handleSessionClosed(session);
      session._failBeforePresentation();
      rethrow;
    }
    return session;
  }

  @override
  Future<void> dismissAll(ActionApprovalCancellationReason reason) async {
    final sessions = List<_MaterialActionApprovalSession>.of(_sessions);
    await Future.wait<void>(
      sessions.map((session) => session.dismiss(reason)),
      eagerError: true,
    );
  }

  void _handleSessionClosed(_MaterialActionApprovalSession session) {
    if (!_sessions.remove(session) || _sessions.isNotEmpty) return;
    final dismissed = _allDismissed;
    _allDismissed = null;
    if (dismissed != null && !dismissed.isCompleted) dismissed.complete();
  }
}

final class _MaterialActionApprovalSession implements ActionApprovalSession {
  _MaterialActionApprovalSession({
    required NavigatorState navigator,
    required RawDialogRoute<void> route,
    required void Function(_MaterialActionApprovalSession) onClosed,
  }) : _navigator = navigator,
       _route = route,
       _onClosed = onClosed;

  final NavigatorState _navigator;
  final RawDialogRoute<void> _route;
  final void Function(_MaterialActionApprovalSession) _onClosed;
  final Completer<ActionApprovalDecision> _decision =
      Completer<ActionApprovalDecision>.sync();
  final Completer<void> _closed = Completer<void>.sync();
  ActionApprovalDecision _settledDecision = ActionApprovalDecision.cancel;
  bool _closeRequested = false;
  bool _completed = false;

  @override
  Future<ActionApprovalDecision> get decision => _decision.future;

  void _attachRouteCompletion(Future<void> completion) {
    unawaited(
      completion.then<void>(
        (_) => _completeAfterRouteClosed(),
        onError: (Object _, StackTrace _) => _completeAfterRouteClosed(),
      ),
    );
  }

  void _failBeforePresentation() {
    _closeRequested = true;
    _completeAfterRouteClosed();
  }

  void select(ActionApprovalDecision decision) {
    if (_closeRequested) return;
    _settledDecision = decision;
    _removeRoute();
  }

  @override
  Future<void> dismiss(ActionApprovalCancellationReason reason) {
    if (!_closeRequested) {
      _settledDecision = ActionApprovalDecision.cancel;
      _removeRoute();
    }
    return _closed.future;
  }

  void _removeRoute() {
    if (_closeRequested) return;
    _closeRequested = true;
    try {
      _navigator.removeRoute<void>(_route);
    } catch (_) {
      // Emergency removal is allowed to retry through Host.dismissAll().
      _closeRequested = false;
      rethrow;
    }
  }

  void _completeAfterRouteClosed() {
    if (_completed) return;
    _completed = true;
    _closeRequested = true;
    if (!_decision.isCompleted) _decision.complete(_settledDecision);
    if (!_closed.isCompleted) _closed.complete();
    _onClosed(this);
  }
}

/// Reports forced Navigator disposal as a definitive Host close acknowledgement.
///
/// `NavigatorState.dispose()` force-disposes its route history without calling
/// `Route.didComplete()`, so the Future returned by `Navigator.push()` is not a
/// sufficient close signal on its own.
final class _ActionApprovalRoute extends RawDialogRoute<void> {
  _ActionApprovalRoute({
    required super.pageBuilder,
    required String routeName,
    required VoidCallback onDisposed,
  }) : _onDisposed = onDisposed,
       super(
         barrierDismissible: false,
         barrierLabel: 'Action approval required',
         barrierColor: Colors.black54,
         transitionDuration: const Duration(milliseconds: 180),
         transitionBuilder: _buildTransition,
         settings: RouteSettings(name: routeName),
         requestFocus: true,
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
       );

  final VoidCallback _onDisposed;
  bool _didNotifyDisposed = false;

  @override
  void dispose() {
    try {
      super.dispose();
    } finally {
      if (!_didNotifyDisposed) {
        _didNotifyDisposed = true;
        _onDisposed();
      }
    }
  }

  static Widget _buildTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

final class _ActionApprovalDialog extends StatelessWidget {
  const _ActionApprovalDialog({required this.prompt, required this.session});

  final ActionApprovalPrompt prompt;
  final _MaterialActionApprovalSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = prompt.presentation;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) session.select(ActionApprovalDecision.cancel);
      },
      child: Semantics(
        namesRoute: true,
        scopesRoute: true,
        explicitChildNodes: true,
        label: presentation.title,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: AlertDialog(
            scrollable: true,
            icon: ExcludeSemantics(
              child: Icon(
                Icons.shield_outlined,
                color: theme.colorScheme.error,
                size: 28,
              ),
            ),
            title: Text(presentation.title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(presentation.description),
                  const SizedBox(height: 16),
                  _ApprovalFact(
                    label: 'action_approval.target'.tr,
                    value: presentation.targetLabel,
                  ),
                  const SizedBox(height: 12),
                  _ApprovalFact(
                    label: 'action_approval.consequence'.tr,
                    value: presentation.consequenceLabel,
                  ),
                  for (final field in presentation.argumentFields) ...<Widget>[
                    const SizedBox(height: 12),
                    _ApprovalFact(label: field.label, value: field.value),
                  ],
                  if (presentation.exactText case final exactText?) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      'action_approval.exact_content'.tr,
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 240),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(exactText),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            actions: <Widget>[
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  autofocus: true,
                  onPressed: () =>
                      session.select(ActionApprovalDecision.reject),
                  child: Text('action_approval.reject'.tr),
                ),
              ),
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: () =>
                      session.select(ActionApprovalDecision.allowOnce),
                  child: Text('action_approval.allow_once'.tr),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ApprovalFact extends StatelessWidget {
  const _ApprovalFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(value),
      ],
    );
  }
}
