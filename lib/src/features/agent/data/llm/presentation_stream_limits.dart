/// Transport limits for one short conversational JSON envelope.
///
/// Provider token budgets are configured separately. A provider may split each
/// logical character into its own event, so fragmentation does not reduce the
/// accepted content budget. Metadata, mirrors and wire overhead remain bounded.
abstract final class PresentationStreamLimits {
  static const maxContentCharacters = 16 * 1024;
  static const maxWireCharacters = 300 * 1024;
  static const maxControlEvents = 272;
  static const maxEvents = maxContentCharacters + maxControlEvents;
}
