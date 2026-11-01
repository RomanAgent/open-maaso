import 'package:shared_preferences/shared_preferences.dart';

import 'account_storage_scope_service.dart';
import 'markdown_document_store_base.dart';

Future<MarkdownDocumentStore> openMarkdownDocumentStore(String fileName) async {
  final preferences = await SharedPreferences.getInstance();
  return _PreferencesMarkdownDocumentStore(
    preferences,
    'maaso.markdown.$fileName',
  );
}

Future<MarkdownDocumentStore> openAccountMarkdownDocumentStore(
  AccountStorageScope scope,
  AccountMarkdownDocumentKind document,
) {
  return _openScopedMarkdownDocumentStore(
    webKeyPrefix: scope.webKeyPrefix,
    fileName: document.fileName,
  );
}

Future<MarkdownDocumentStore> openAgentMarkdownDocumentStore(
  AgentStorageScope scope,
  AgentMarkdownDocumentKind document,
) {
  return _openScopedMarkdownDocumentStore(
    webKeyPrefix: scope.webKeyPrefix,
    fileName: document.fileName,
  );
}

Future<MarkdownDocumentStore> _openScopedMarkdownDocumentStore({
  required String webKeyPrefix,
  required String fileName,
}) async {
  final preferences = await SharedPreferences.getInstance();
  return _PreferencesMarkdownDocumentStore(
    preferences,
    '$webKeyPrefix.markdown.$fileName',
  );
}

final class _PreferencesMarkdownDocumentStore implements MarkdownDocumentStore {
  _PreferencesMarkdownDocumentStore(this._preferences, this._key);

  final SharedPreferences _preferences;
  final String _key;

  @override
  Future<String?> read() async => _preferences.getString(_key);

  @override
  Future<void> write(String contents) async {
    final saved = await _preferences.setString(_key, contents);
    if (!saved) {
      throw StateError('Failed to persist $_key.');
    }
  }
}
