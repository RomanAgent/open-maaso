import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/features/settings/presentation/device_handoff_panel.dart';

/// Authenticated boundary shown while this device does not own runtime
/// authority. No account-scoped route dependency is created for this page.
class AccountStandbyPage extends StatefulWidget {
  const AccountStandbyPage({super.key});

  @override
  State<AccountStandbyPage> createState() => _AccountStandbyPageState();
}

class _AccountStandbyPageState extends State<AccountStandbyPage> {
  late final AccountSessionLifecycleService _lifecycle = appServices
      .find<AccountSessionLifecycleService>();
  bool _retrying = false;
  Object? _actionError;

  @override
  Widget build(BuildContext context) {
    final handoff = appServices.maybeFind<AgentHandoffService>();
    return ListenableBuilder(
      listenable: Listenable.merge([_lifecycle, handoff]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final conflict = _lifecycle.leaseConflict;
        final phase = _lifecycle.phase.value;
        // Route refresh can briefly visit standby while a session is being
        // restored or recovered. Those transitions are not failed attempts.
        final transitioning =
            _retrying ||
            _lifecycle.presenceRecoveryInProgress ||
            switch (phase) {
              AccountSessionLifecyclePhase.authenticatedStandby ||
              AccountSessionLifecyclePhase.leaseConflict ||
              AccountSessionLifecyclePhase.verificationRequired ||
              AccountSessionLifecyclePhase.faulted => false,
              _ => true,
            };
        final (title, message, icon) = switch (phase) {
          AccountSessionLifecyclePhase.acquiringLease => (
            'Connecting this device',
            'Maaso is checking runtime authority before opening your local '
                'account data.',
            Icons.sync_rounded,
          ),
          AccountSessionLifecyclePhase.leaseConflict => (
            'Your Agent is active elsewhere',
            'This device remains safely signed in without loading the Agent '
                'runtime.',
            Icons.devices_rounded,
          ),
          AccountSessionLifecyclePhase.verificationRequired => (
            'Session verification required',
            'Verify your sign-in, then retry. Local account data has not been '
                'opened.',
            Icons.verified_user_outlined,
          ),
          AccountSessionLifecyclePhase.retiring => (
            'Securing this device',
            'Maaso is draining the previous runtime before another attempt.',
            Icons.shield_outlined,
          ),
          AccountSessionLifecyclePhase.faulted => (
            'Cleanup needs attention',
            'Retry after the local runtime finishes closing, or sign out.',
            Icons.warning_amber_rounded,
          ),
          _ => (
            'Signed in on standby',
            'This device will stay inactive until it holds the exact runtime '
                'lease.',
            Icons.pause_circle_outline_rounded,
          ),
        };

        return Scaffold(
          // Hidden preparation may already have a default actor in Unity.
          // Standby must stay opaque even under a transparent app theme.
          backgroundColor: theme.colorScheme.surface.withValues(alpha: 1),
          body: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(color: theme.scaffoldBackgroundColor),
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: transitioning
                            ? const _StandbyLoading()
                            : Card(
                                elevation: 0,
                                color: theme.colorScheme.surface.withValues(
                                  alpha: 0.86,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(28),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: <Widget>[
                                      Icon(
                                        icon,
                                        size: 44,
                                        color: theme.colorScheme.primary,
                                      ),
                                      const SizedBox(height: 18),
                                      Text(
                                        title,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.headlineSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        message,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.bodyLarge,
                                      ),
                                      if (conflict != null) ...<Widget>[
                                        const SizedBox(height: 20),
                                        _HolderDetails(
                                          label: conflict.holder.deviceLabel,
                                          platform: conflict.holder.platform,
                                          lastSeenAt:
                                              conflict.holder.lastSeenAt,
                                          expiresAt: conflict.expiresAt,
                                        ),
                                      ],
                                      if (_actionError != null) ...<Widget>[
                                        const SizedBox(height: 16),
                                        Text(
                                          'account_standby.request_failed'.tr,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: theme.colorScheme.error,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 24),
                                      FilledButton.icon(
                                        onPressed: _retrying ? null : _retry,
                                        icon: _retrying
                                            ? const SizedBox.square(
                                                dimension: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(Icons.refresh_rounded),
                                        label: Text('common.retry'.tr),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        handoffText(
                                          context,
                                          '在人物所在设备的设置中选择「跨设备移动」，就能走到这里。请保持此设备在线。',
                                          'On the device with your Agent, open Settings → Move between devices and choose this device. Keep Maaso open here.',
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 10),
                                      TextButton(
                                        onPressed: () => unawaited(_signOut()),
                                        child: Text(
                                          'account_standby.sign_out'.tr,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _retry() async {
    setState(() {
      _retrying = true;
      _actionError = null;
    });
    try {
      if (_lifecycle.isFaulted) {
        await _lifecycle.retryFaultedCleanup();
      }
      await _lifecycle.mountCurrentSession();
    } catch (error) {
      if (mounted) setState(() => _actionError = error);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _signOut() async {
    try {
      await _lifecycle.signOutAndUnmount();
    } catch (error) {
      if (mounted) setState(() => _actionError = error);
    }
  }
}

class _StandbyLoading extends StatelessWidget {
  const _StandbyLoading();

  @override
  Widget build(BuildContext context) {
    final message = handoffText(
      context,
      '正在准备此设备，请稍候。',
      'Getting this device ready. Please wait.',
    );
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 20),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _HolderDetails extends StatelessWidget {
  const _HolderDetails({
    required this.label,
    required this.platform,
    required this.lastSeenAt,
    required this.expiresAt,
  });

  final String label;
  final String platform;
  final DateTime lastSeenAt;
  final DateTime expiresAt;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: style?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Platform: $platform', style: style),
            Text('Last seen: ${lastSeenAt.toLocal()}', style: style),
            Text('Lease expires: ${expiresAt.toLocal()}', style: style),
          ],
        ),
      ),
    );
  }
}
