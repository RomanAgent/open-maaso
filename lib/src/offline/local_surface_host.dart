import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/offline/local_edition_policy.dart';
import 'package:maaso/src/offline/offline_document.dart';
import 'package:maaso/src/offline/offline_network_guard.dart';
import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Keeps the original player UI and authored source intact. Only the runtime
/// document gets an offline policy; data/blob scripts support the existing
/// host bundler and local workerCanvas runtime.
const localSurfaceContentSecurityPolicy =
    "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' data: blob:; style-src 'unsafe-inline' data: blob:; img-src data: blob:; font-src data: blob:; media-src data: blob:; connect-src 'none'; frame-src data: blob: about:; worker-src data: blob:; object-src 'none'; base-uri 'none'; form-action 'none'";

String localSurfaceDocument(
  String document,
  Map<String, String> state, {
  String? storageToken,
  bool enableStorage = true,
}) {
  if (!kOpenMaasoLocalEdition) return document;
  final storage = enableStorage
      ? '<script>${offlineStoragePrelude(state, scopeToken: storageToken)}</script>'
      : '';
  final prelude =
      '<meta http-equiv="Content-Security-Policy" content="$localSurfaceContentSecurityPolicy">$storage';
  final head = RegExp(
    r'<head(?:\s[^>]*)?>',
    caseSensitive: false,
  ).firstMatch(document);
  if (head != null) {
    return document.replaceRange(head.end, head.end, prelude);
  }
  return '<!doctype html><html><head>$prelude</head><body>$document</body></html>';
}

WebViewController createLocalSurfaceController() {
  if (!kOpenMaasoLocalEdition) return WebViewController();
  final platform = WebViewPlatform.instance;
  if (platform is WebKitWebViewPlatform) {
    return WebViewController.fromPlatformCreationParams(
      WebKitWebViewControllerCreationParams(
        useNonPersistentDataStore: true,
        javaScriptCanOpenWindowsAutomatically: false,
      ),
    );
  }
  if (platform is AndroidWebViewPlatform) {
    return WebViewController.fromPlatformCreationParams(
      AndroidWebViewControllerCreationParams(
        invocationProfileName:
            'maaso_offline_${const Uuid().v4().replaceAll('-', '')}',
      ),
    );
  }
  // Existing fake platforms retain their seam. Real player host admission
  // already excludes platforms without the native iOS/Android WebView host.
  return WebViewController();
}

Future<void> configureLocalSurfaceController(
  WebViewController controller,
) async {
  if (!kOpenMaasoLocalEdition) return;
  if (controller.platform case final WebKitWebViewController webkit) {
    await webkit.addOfflineDocumentStartScript(offlineNetworkGuardScript);
  } else if (controller.platform is AndroidWebViewController) {
    if (!await AndroidWebViewController.supportsInvocationProfiles()) {
      throw StateError('offline_browser_isolation_unavailable');
    }
  }
}

Future<void> disposeLocalSurfaceController(WebViewController controller) async {
  if (!kOpenMaasoLocalEdition) return;
  if (controller.platform case final AndroidWebViewController android) {
    await android.disposeInvocationProfile();
  }
}

/// Native browser profiles are ephemeral. Keep ordinary localStorage changes
/// in the same account-scoped Sembast database as the original works.
final class LocalSurfaceStorage {
  LocalSurfaceStorage._(this._database, this._key, this.state);
  static final _store = stringMapStoreFactory.store('local_surface_storage_v1');
  static final Expando<Map<String, Future<void>>> _writes = Expando();
  final DBService? _database;
  final String _key;
  Map<String, String> state;
  final String nonce = const Uuid().v4();

  static Future<LocalSurfaceStorage> open(String projectId) async {
    final database = appServices.maybeFind<DBService>();
    final state = <String, String>{};
    if (database != null) {
      final pending = _writes[database]?[projectId];
      if (pending != null) await pending;
      final stored = await _store.record(projectId).get(database.raw);
      if (stored != null) {
        for (final entry in stored.entries) {
          if (entry.value is String) state[entry.key] = entry.value as String;
        }
      }
    }
    return LocalSurfaceStorage._(database, projectId, state);
  }

  void receive(String source) {
    final database = _database;
    if (database == null ||
        !identical(database, appServices.maybeFind<DBService>())) {
      return;
    }
    if (source.length > 524288) return;
    try {
      final event = jsonDecode(source);
      if (event is! Map || event['scopeToken'] != nonce) return;
    } on FormatException {
      return;
    }
    final next = applyOfflineStorageEvent(state, source);
    if (next == null) return;
    state = next;
    // Register the DB operation immediately, before account teardown can
    // enqueue database.close. Never redirect a late event to another DB.
    final writes = _writes[database] ??= <String, Future<void>>{};
    late final Future<void> operation;
    operation = _store
        .record(_key)
        .put(database.raw, next)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(writes[_key], operation)) writes.remove(_key);
        });
    writes[_key] = operation;
    unawaited(operation);
  }
}
