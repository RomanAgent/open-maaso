abstract interface class MarkdownDocumentStore {
  Future<String?> read();

  Future<void> write(String contents);
}

/// Account-owned Markdown documents supported by the scoped persistence API.
enum AccountMarkdownDocumentKind { master }

/// Agent-owned Markdown documents supported by the scoped persistence API.
enum AgentMarkdownDocumentKind { soul, world }

extension AccountMarkdownDocumentKindStorageName
    on AccountMarkdownDocumentKind {
  String get fileName => switch (this) {
    AccountMarkdownDocumentKind.master => 'master.md',
  };
}

extension AgentMarkdownDocumentKindStorageName on AgentMarkdownDocumentKind {
  String get fileName => switch (this) {
    AgentMarkdownDocumentKind.soul => 'soul.md',
    AgentMarkdownDocumentKind.world => 'world.md',
  };
}
