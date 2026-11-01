import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppControl page action schema gate', () {
    test('rejects invalid arguments before the page handler runs', () async {
      final action = _action(argumentsSchema: _boundedTopicSchema);
      final invalidArguments = <Map<String, Object?>>[
        const <String, Object?>{},
        const <String, Object?>{'topic': 'valid', 'extra': true},
        const <String, Object?>{'topic': '12345'},
      ];

      for (final arguments in invalidArguments) {
        final result = await _runAction(action: action, arguments: arguments);

        expect(result.response['status'], 'error');
        expect(result.response['error'], 'invalid_arguments');
        expect(result.handlerCalls, 0);
      }
    });

    test('rejects malformed host input schemas without invoking', () async {
      final result = await _runAction(
        action: _action(
          argumentsSchema: const <String, Object?>{'type': 'host-secret'},
        ),
        arguments: const <String, Object?>{'topic': 'safe'},
      );

      expect(result.response, <String, Object?>{
        'status': 'error',
        'error': 'host_schema_invalid',
      });
      expect(result.handlerCalls, 0);
    });

    test('allows only non-consequential action metadata', () async {
      final safePolicies = <(ActionRisk, ActionConsequencePolicy)>[
        (ActionRisk.readOnly, ActionConsequencePolicy.reversible),
        (ActionRisk.localMutation, ActionConsequencePolicy.prepareOnly),
      ];

      for (final policy in safePolicies) {
        final result = await _runAction(
          action: _action(risk: policy.$1, consequencePolicy: policy.$2),
          arguments: const <String, Object?>{'topic': 'safe'},
        );

        expect(result.response['status'], 'ok');
        expect(result.response['accepted'], isTrue);
        expect(result.handlerCalls, 1);
      }
    });

    test('fails closed for every approval-requiring risk', () async {
      for (final risk in <ActionRisk>[
        ActionRisk.externalWrite,
        ActionRisk.physicalAction,
        ActionRisk.destructive,
      ]) {
        final result = await _runAction(
          action: _action(risk: risk),
          arguments: const <String, Object?>{'topic': 'safe'},
        );

        expect(result.response['error'], 'approval_required');
        expect(result.handlerCalls, 0);
      }
    });

    test('fails closed for every approval-requiring consequence', () async {
      for (final consequence in <ActionConsequencePolicy>[
        ActionConsequencePolicy.exactTextCommit,
        ActionConsequencePolicy.destructive,
      ]) {
        final result = await _runAction(
          action: _action(consequencePolicy: consequence),
          arguments: const <String, Object?>{'topic': 'safe'},
        );

        expect(result.response['error'], 'approval_required');
        expect(result.handlerCalls, 0);
      }
    });

    test('rejects invalid handler output without exposing it', () async {
      const secret = 'private-handler-result';
      final result = await _runAction(
        action: _action(
          resultSchema: const <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'accepted': <String, Object?>{'const': true},
            },
            'required': <String>['accepted'],
            'additionalProperties': false,
          },
        ),
        arguments: const <String, Object?>{'topic': 'safe'},
        handlerResult: const <String, Object?>{
          'accepted': false,
          'detail': secret,
        },
      );

      expect(result.response, <String, Object?>{
        'status': 'error',
        'error': 'invalid_result',
      });
      expect(jsonEncode(result.response), isNot(contains(secret)));
      expect(result.handlerCalls, 1);
    });

    test('freezes nested result schema across the handler await', () async {
      const secret = 'mutated-schema-result';
      final acceptedRule = <String, Object?>{'const': true};
      final resultSchema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{'accepted': acceptedRule},
        'required': <String>['accepted'],
        'additionalProperties': false,
      };
      final action = _action(resultSchema: resultSchema);

      final result = await _runAction(
        action: action,
        arguments: const <String, Object?>{'topic': 'safe'},
        beforeHandler: () {
          acceptedRule['const'] = false;
          (resultSchema['properties']! as Map)['detail'] =
              const <String, Object?>{'type': 'string'};
        },
        handlerResult: const <String, Object?>{
          'accepted': false,
          'detail': secret,
        },
      );

      expect(result.response, <String, Object?>{
        'status': 'error',
        'error': 'invalid_result',
      });
      expect(jsonEncode(result.response), isNot(contains(secret)));
      expect(result.handlerCalls, 1);
    });

    test('rejects malformed host result schemas before invocation', () async {
      final result = await _runAction(
        action: _action(
          resultSchema: const <String, Object?>{'unsupported': true},
        ),
        arguments: const <String, Object?>{'topic': 'safe'},
      );

      expect(result.response, <String, Object?>{
        'status': 'error',
        'error': 'host_schema_invalid',
      });
      expect(result.handlerCalls, 0);
    });
  });
}

const Map<String, Object?> _boundedTopicSchema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{
    'topic': <String, Object?>{
      'type': 'string',
      'minLength': 1,
      'maxLength': 4,
    },
  },
  'required': <String>['topic'],
  'additionalProperties': false,
};

AppControlPageAction _action({
  Map<String, Object?> argumentsSchema = _boundedTopicSchema,
  Map<String, Object?> resultSchema = const <String, Object?>{'type': 'object'},
  ActionRisk risk = ActionRisk.readOnly,
  ActionConsequencePolicy consequencePolicy =
      ActionConsequencePolicy.reversible,
}) => AppControlPageAction(
  id: 'contract_action',
  description: 'Exercise the page action contract.',
  argumentsSchema: argumentsSchema,
  resultSchema: resultSchema,
  risk: risk,
  consequencePolicy: consequencePolicy,
);

Future<_RunResult> _runAction({
  required AppControlPageAction action,
  required Map<String, Object?> arguments,
  Map<String, Object?> handlerResult = const <String, Object?>{
    'accepted': true,
  },
  void Function()? beforeHandler,
}) async {
  final coordinator = AgentUiControlCoordinator();
  final uiControl = AgentUiControlService(coordinator: coordinator);
  final adapter = _ContractPageAdapter(
    action: action,
    handlerResult: handlerResult,
    beforeHandler: beforeHandler,
  );
  PageAgentAdapterRegistration<_ContractPageAdapter>? registration;
  final navigation = _ContractNavigation(
    onPush: (_) {
      registration = uiControl.adapters.register(adapter);
    },
  );
  final skill = AppControlSkill(
    navigation: navigation,
    uiControl: uiControl,
    routeReadinessBarrier: () async {},
    routeReadinessTimeout: const Duration(milliseconds: 200),
  );

  try {
    final raw = await skill.methods['execute']!(<Object>[
      jsonEncode(<String, Object?>{
        'page': 'widgets_hub',
        'action': action.id,
        'arguments': arguments,
      }),
    ]);
    return _RunResult(
      response: Map<String, Object?>.from(jsonDecode(raw as String) as Map),
      handlerCalls: adapter.handlerCalls,
    );
  } finally {
    registration?.unregister();
    await coordinator.dispose();
  }
}

final class _RunResult {
  const _RunResult({required this.response, required this.handlerCalls});

  final Map<String, Object?> response;
  final int handlerCalls;
}

final class _ContractNavigation extends AppNavigation {
  _ContractNavigation({required this.onPush});

  final void Function(String route) onPush;
  final Completer<Object?> _pendingPush = Completer<Object?>();
  String _currentRoute = '/home';

  @override
  bool get isConfigured => true;

  @override
  String get currentRoute => _currentRoute;

  @override
  Future<T?> push<T extends Object?>(String route, {Object? extra}) {
    _currentRoute = route;
    onPush(route);
    return _pendingPush.future.then<T?>((value) => value as T?);
  }
}

final class _ContractPageAdapter implements AppControlPageAdapter {
  _ContractPageAdapter({
    required this.action,
    required this.handlerResult,
    this.beforeHandler,
  });

  final AppControlPageAction action;
  final Map<String, Object?> handlerResult;
  final void Function()? beforeHandler;
  int handlerCalls = 0;

  @override
  String get route => '/widgets-hub';

  @override
  List<AppControlPageAction> get appControlActions => <AppControlPageAction>[
    action,
  ];

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    executionContext.checkpoint();
    handlerCalls += 1;
    beforeHandler?.call();
    return AgentUiControlResult<Map<String, Object?>>.success(handlerResult);
  }
}
