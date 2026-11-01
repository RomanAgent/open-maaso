import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'public_web_page_url_policy.dart';

typedef PublicWebPageLookup =
    Future<List<InternetAddress>> Function(String host);
typedef PublicWebPageConnect =
    Future<ConnectionTask<Socket>> Function(InternetAddress address, int port);

http.Client createPublicWebPageClient() => PublicWebPageIoClient();

/// Each reader call owns a fresh instance: no cookie jar, credentials, proxy,
/// or authenticated connection from another app service can be reused.
class PublicWebPageIoClient extends http.BaseClient {
  PublicWebPageIoClient({
    PublicWebPageLookup? lookup,
    PublicWebPageConnect? connect,
  }) : _lookup = lookup ?? InternetAddress.lookup,
       _connect = connect ?? Socket.startConnect {
    final inner = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = _openPublicConnection;
    _http = IOClient(inner);
  }

  final PublicWebPageLookup _lookup;
  final PublicWebPageConnect _connect;
  final _connections = <ConnectionTask<Socket>>[];
  late final http.Client _http;
  bool _closed = false;

  Future<ConnectionTask<Socket>> _openPublicConnection(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    validatePublicWebPageUrl(uri.toString());
    if (_closed || proxyHost != null || proxyPort != null) {
      throw const PublicWebPageRequestException(
        'connection_unavailable',
        failureStage: 'connect',
      );
    }
    final addresses = await _lookup(uri.host);
    if (_closed) {
      throw const PublicWebPageRequestException(
        'request_cancelled',
        failureStage: 'dns',
      );
    }
    if (addresses.isEmpty ||
        addresses.any(
          (address) => !isPublicWebPageAddressBytes(address.rawAddress),
        )) {
      throw const PublicWebPageRequestException(
        'non_public_address',
        failureStage: 'dns',
      );
    }
    // Pass an InternetAddress object, never the hostname, to avoid a second
    // DNS resolution between validation and the actual connection. TLS still
    // validates the original URL hostname in HttpClient.
    final address = addresses.firstWhere(
      (address) => address.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
    final task = await _connect(address, uri.port);
    if (_closed) {
      task.cancel();
      throw const PublicWebPageRequestException(
        'request_cancelled',
        failureStage: 'connect',
      );
    }
    _connections.add(task);
    return task;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    validatePublicWebPageUrl(request.url.toString());
    if (_closed) {
      throw const PublicWebPageRequestException(
        'request_cancelled',
        failureStage: 'connect',
      );
    }
    return _http.send(request);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final task in _connections) {
      task.cancel();
    }
    _connections.clear();
    _http.close();
  }
}
