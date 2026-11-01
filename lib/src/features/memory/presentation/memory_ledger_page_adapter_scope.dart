import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_host_command_executor.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_page_adapter.dart';

/// Registers the semantic adapter owned by one mounted Memory Ledger route.
class MemoryLedgerPageAdapterScope extends StatefulWidget {
  const MemoryLedgerPageAdapterScope({
    super.key,
    required this.target,
    required this.child,
    this.uiControl,
    this.hostCommandExecutor,
  });

  final MemoryLedgerPageTarget target;
  final Widget child;
  final AgentUiControlService? uiControl;
  final MemoryLedgerHostCommandExecutor? hostCommandExecutor;

  @override
  State<MemoryLedgerPageAdapterScope> createState() =>
      _MemoryLedgerPageAdapterScopeState();
}

class _MemoryLedgerPageAdapterScopeState
    extends State<MemoryLedgerPageAdapterScope> {
  MemoryLedgerPageTarget? _target;
  AgentUiControlService? _uiControl;
  MemoryLedgerHostCommandExecutor? _hostCommandExecutor;
  MemoryLedgerPageAdapter? _adapter;
  PageAgentAdapterRegistration<MemoryLedgerPageAdapter>? _registration;
  MemoryLedgerHostCommandRegistration? _hostCommandRegistration;

  @override
  void initState() {
    super.initState();
    _mount();
  }

  @override
  void didUpdateWidget(MemoryLedgerPageAdapterScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextUiControl =
        widget.uiControl ?? appServices.maybeFind<AgentUiControlService>();
    final nextHostCommandExecutor =
        widget.hostCommandExecutor ??
        appServices.maybeFind<MemoryLedgerHostCommandExecutor>();
    if (identical(_target, widget.target) &&
        identical(_uiControl, nextUiControl) &&
        identical(_hostCommandExecutor, nextHostCommandExecutor)) {
      return;
    }
    _unmount();
    _mount(
      resolvedUiControl: nextUiControl,
      resolvedHostCommandExecutor: nextHostCommandExecutor,
    );
  }

  void _mount({
    AgentUiControlService? resolvedUiControl,
    MemoryLedgerHostCommandExecutor? resolvedHostCommandExecutor,
  }) {
    final uiControl =
        resolvedUiControl ??
        widget.uiControl ??
        appServices.maybeFind<AgentUiControlService>();
    final hostCommandExecutor =
        resolvedHostCommandExecutor ??
        widget.hostCommandExecutor ??
        appServices.maybeFind<MemoryLedgerHostCommandExecutor>();
    if (uiControl == null) return;
    final adapter = MemoryLedgerPageAdapter(
      uiCoordinator: uiControl.coordinator,
      target: widget.target,
    );
    _target = widget.target;
    _uiControl = uiControl;
    _hostCommandExecutor = hostCommandExecutor;
    _adapter = adapter;
    _registration = uiControl.adapters.register(adapter);
    _hostCommandRegistration = hostCommandExecutor?.attachVisibleAdapter(
      adapter,
    );
  }

  void _unmount() {
    _hostCommandRegistration?.unregister();
    _adapter?.detach();
    _registration?.unregister();
    _target = null;
    _uiControl = null;
    _hostCommandExecutor = null;
    _adapter = null;
    _registration = null;
    _hostCommandRegistration = null;
  }

  @override
  void dispose() {
    _unmount();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
