import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skills/public_web_page_client_io.dart';
import 'package:maaso/src/features/agent/application/skills/public_web_page_reader.dart';
import 'package:maaso/src/features/agent/application/skills/public_web_page_url_policy.dart';

void main() {
  for (final answers in [
    ['127.0.0.1'],
    ['10.0.0.1'],
    ['198.18.0.1'],
    ['::ffff:127.0.0.1'],
    ['64:ff9b::7f00:1'],
    ['64:ff9b::a00:1'],
    ['64:ff9b::c612:1'],
    ['64:ff9b:1::808:808'],
    ['64:ff9b::808:808', '64:ff9b::c0a8:101'],
    ['1.1.1.1', '192.168.1.1'],
    <String>[],
  ]) {
    test(
      'DNS answers $answers are rejected without opening a socket',
      () async {
        var connections = 0;
        final client = PublicWebPageIoClient(
          lookup: (_) async => answers.map(InternetAddress.new).toList(),
          connect: (_, _) async {
            connections++;
            throw StateError('must not connect');
          },
        );
        addTearDown(client.close);
        final result = await PublicWebPageReader(
          client: client,
        ).read('https://example.com');
        expect(result['error'], 'non_public_address');
        expect(result['failureStage'], 'dns');
        expect(connections, 0);
      },
    );
  }

  test(
    'connects to the checked address object without resolving hostname again',
    () async {
      var lookups = 0;
      InternetAddress? connectedAddress;
      int? connectedPort;
      final client = PublicWebPageIoClient(
        lookup: (host) async {
          expect(host, 'example.com');
          lookups++;
          // A second DNS lookup would rebind to localhost.
          return [InternetAddress(lookups == 1 ? '1.1.1.1' : '127.0.0.1')];
        },
        connect: (address, port) async {
          connectedAddress = address;
          connectedPort = port;
          throw const PublicWebPageRequestException(
            'binding_probe',
            failureStage: 'connect',
          );
        },
      );
      addTearDown(client.close);
      final result = await PublicWebPageReader(
        client: client,
      ).read('https://example.com');
      expect(result['error'], 'binding_probe');
      expect(lookups, 1);
      expect(connectedAddress?.address, '1.1.1.1');
      expect(connectedPort, 443);
    },
  );

  test(
    'NAT64 public DNS address is passed intact to the socket connector',
    () async {
      var lookups = 0;
      InternetAddress? connectedAddress;
      final client = PublicWebPageIoClient(
        lookup: (_) async {
          lookups++;
          return [InternetAddress('64:ff9b::808:808')];
        },
        connect: (address, port) async {
          connectedAddress = address;
          expect(port, 443);
          throw const PublicWebPageRequestException(
            'binding_probe',
            failureStage: 'connect',
          );
        },
      );
      addTearDown(client.close);
      final result = await PublicWebPageReader(
        client: client,
      ).read('https://example.com');
      expect(result['error'], 'binding_probe');
      expect(lookups, 1);
      expect(connectedAddress?.address, '64:ff9b::808:808');
      expect(connectedAddress?.type, InternetAddressType.IPv6);
    },
  );

  test('client closed during pending DNS cannot later open a socket', () async {
    final dns = Completer<List<InternetAddress>>();
    final lookupStarted = Completer<void>();
    var connections = 0;
    final client = PublicWebPageIoClient(
      lookup: (_) {
        lookupStarted.complete();
        return dns.future;
      },
      connect: (_, _) async {
        connections++;
        throw StateError('must not connect after closing');
      },
    );
    final future = PublicWebPageReader(
      client: client,
    ).read('https://example.com');
    await lookupStarted.future;
    client.close();
    dns.complete([InternetAddress('1.1.1.1')]);
    final result = await future;
    expect(result['status'], 'failed');
    expect(connections, 0);
  });
}
