import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/desktop/infrastructure/method_channel_macos_desktop_companion_host_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    MethodChannelMacOSDesktopCompanionHostGateway.channelName,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'method channel drives the native panel and receives semantic callbacks',
    () async {
      final outbound = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            outbound.add(call);
            return null;
          });
      final gateway = MethodChannelMacOSDesktopCompanionHostGateway();
      String? selected;
      DesktopCompanionHostCommand? command;
      Offset? gaze;
      final interactions = <DesktopAvatarInteractionV1>[];

      await gateway.initialize(
        onMenuSelected: (value) => selected = value,
        onCommand: (value) => command = value,
        onGazeChanged: (value) => gaze = value,
        onInteraction: interactions.add,
      );
      await gateway.configurePresentation(
        DesktopCompanionPresentationConfigV1.defaults,
      );
      await gateway.configureMenu(const <DesktopCompanionHostMenuItem>[
        DesktopCompanionHostMenuItem(id: 'chat', label: 'Chat'),
      ]);
      await gateway.show(interactionGeneration: 7);
      await gateway.showBubble('hello');

      expect(
        outbound.map((call) => call.method),
        containsAllInOrder(<String>[
          'configurePresentation',
          'configureMenu',
          'show',
          'showBubble',
        ]),
      );
      final presentation = outbound.firstWhere(
        (call) => call.method == 'configurePresentation',
      );
      expect(presentation.arguments, <String, Object>{
        'version': 1,
        'quality': 'crisp',
        'targetFps': 30,
        'visualScale': 1.8,
        'alwaysOnTop': true,
        'snapEnabled': false,
        'snapAcquireDistance': 24.0,
        'snapReleaseDistance': 40.0,
      });
      final show = outbound.firstWhere((call) => call.method == 'show');
      expect(show.arguments, <String, Object>{'interactionGeneration': 7});

      await _sendNativeCall(
        channel,
        const MethodCall('menuSelected', <String, Object>{'id': 'chat'}),
      );
      await _sendNativeCall(
        channel,
        const MethodCall('command', <String, Object>{'id': 'hidePet'}),
      );
      await _sendNativeCall(
        channel,
        const MethodCall('gazeChanged', <String, Object>{
          'active': true,
          'x': 1.5,
          'y': -0.25,
        }),
      );

      expect(selected, 'chat');
      expect(command, DesktopCompanionHostCommand.hidePet);
      expect(gaze, const Offset(1, -0.25));

      await _sendNativeCall(
        channel,
        const MethodCall('gazeChanged', <String, Object>{'active': false}),
      );
      expect(gaze, isNull);

      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', _interactionPayload(7, 100)),
      );
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', _interactionPayload(7, 100)),
      );
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', _interactionPayload(7, 99)),
      );
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', _interactionPayload(8, 101)),
      );

      expect(interactions, hasLength(1));
      expect(interactions.single.region, DesktopAvatarInteractionRegion.head);
      expect(interactions.single.generation, 7);
      expect(interactions.single.timestampMs, 100);

      await gateway.show(interactionGeneration: 8);
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', _interactionPayload(8, 1)),
      );
      expect(interactions, hasLength(2));

      await gateway.hide();
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', _interactionPayload(8, 2)),
      );
      expect(interactions, hasLength(2));

      await gateway.dispose();
      expect(outbound.last.method, 'dispose');
    },
  );

  test('missing presentation method keeps legacy native defaults', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'configurePresentation') {
            throw MissingPluginException();
          }
          return null;
        });
    final gateway = MethodChannelMacOSDesktopCompanionHostGateway();

    await expectLater(
      gateway.configurePresentation(
        DesktopCompanionPresentationConfigV1.defaults,
      ),
      completes,
    );
  });

  test(
    'disposing an old gateway cannot clear the replacement handler',
    () async {
      final outbound = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            outbound.add(call);
            return null;
          });
      final oldGateway = MethodChannelMacOSDesktopCompanionHostGateway();
      final replacement = MethodChannelMacOSDesktopCompanionHostGateway();
      String? selected;

      await oldGateway.initialize(
        onMenuSelected: (_) {},
        onCommand: (_) {},
        onGazeChanged: (_) {},
        onInteraction: (_) {},
      );
      await replacement.initialize(
        onMenuSelected: (value) => selected = value,
        onCommand: (_) {},
        onGazeChanged: (_) {},
        onInteraction: (_) {},
      );
      await oldGateway.dispose();
      await _sendNativeCall(
        channel,
        const MethodCall('menuSelected', <String, Object>{'id': 'settings'}),
      );

      expect(selected, 'settings');
      expect(outbound.where((call) => call.method == 'dispose'), isEmpty);

      await replacement.dispose();
      expect(outbound.last.method, 'dispose');
    },
  );

  test(
    'malformed avatar interactions are ignored by the strict codec',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      final gateway = MethodChannelMacOSDesktopCompanionHostGateway();
      final interactions = <DesktopAvatarInteractionV1>[];
      await gateway.initialize(
        onMenuSelected: (_) {},
        onCommand: (_) {},
        onGazeChanged: (_) {},
        onInteraction: interactions.add,
      );
      await gateway.show(interactionGeneration: 2);

      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', <String, Object>{
          ..._interactionPayload(2, 1),
          'extra': true,
        }),
      );
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', <String, Object>{
          ..._interactionPayload(2, 2),
          'normalizedX': double.nan,
        }),
      );
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', <String, Object>{
          ..._interactionPayload(2, 3),
          'region': 'neck',
        }),
      );

      expect(interactions, isEmpty);
      await gateway.dispose();
    },
  );

  test(
    'dispose and initialize reset the accepted interaction generation',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      final gateway = MethodChannelMacOSDesktopCompanionHostGateway();
      final first = <DesktopAvatarInteractionV1>[];
      await gateway.initialize(
        onMenuSelected: (_) {},
        onCommand: (_) {},
        onGazeChanged: (_) {},
        onInteraction: first.add,
      );
      await gateway.show(interactionGeneration: 9);
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', _interactionPayload(9, 20)),
      );
      expect(first, hasLength(1));
      await gateway.dispose();

      final second = <DesktopAvatarInteractionV1>[];
      await gateway.initialize(
        onMenuSelected: (_) {},
        onCommand: (_) {},
        onGazeChanged: (_) {},
        onInteraction: second.add,
      );
      await gateway.show(interactionGeneration: 1);
      await _sendNativeCall(
        channel,
        MethodCall('avatarInteraction', _interactionPayload(1, 0)),
      );

      expect(second, hasLength(1));
      expect(second.single.generation, 1);
      await gateway.dispose();
    },
  );
}

Map<String, Object> _interactionPayload(int generation, int timestampMs) =>
    <String, Object>{
      'version': 1,
      'type': 'tap',
      'normalizedX': 0.4,
      'normalizedY': 0.2,
      'region': 'head',
      'generation': generation,
      'timestampMs': timestampMs,
    };

Future<void> _sendNativeCall(MethodChannel channel, MethodCall call) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = channel.codec.encodeMethodCall(call);
  await messenger.handlePlatformMessage(channel.name, data, (_) {});
}
