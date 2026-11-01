import 'account_storage_scope_service.dart';
import 'markdown_document_store_base.dart';

Future<MarkdownDocumentStore> openMarkdownDocumentStore(String fileName) {
  throw UnsupportedError(
    'No Markdown document store is available for $fileName on this platform.',
  );
}

Future<MarkdownDocumentStore> openAccountMarkdownDocumentStore(
  AccountStorageScope scope,
  AccountMarkdownDocumentKind document,
) {
  throw UnsupportedError(
    'No scoped Markdown document store is available for '
    '${document.fileName} on this platform.',
  );
}

Future<MarkdownDocumentStore> openAgentMarkdownDocumentStore(
  AgentStorageScope scope,
  AgentMarkdownDocumentKind document,
) {
  throw UnsupportedError(
    'No scoped Markdown document store is available for '
    '${document.fileName} on this platform.',
  );
}
