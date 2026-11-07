# Maaso invocation isolation patch

Pinned upstream: `webview_flutter_android` `4.13.0`. `UPSTREAM_SOURCE.json` records the SHA-256 of each original copied file. Upstream LICENSE is retained. No pub-cache file is edited.

This fork adds an explicit opt-in data-container constructor before any authored document loads. The normal constructor remains unchanged. iOS/macOS use a fresh nonpersistent WKWebsiteDataStore per configuration; Android uses a per-invocation AndroidX WebView profile, requires MULTI_PROFILE support, and never falls back to the shared default profile.

Pigeon schema and checked-in Dart/native channel bindings receive the same narrow additions. Pigeon was not installed locally when this patch was prepared: wire bindings are updated following the pinned generated named-constructor pattern, rather than claiming a generator run. Validate the matching channel names, codec arguments, default-path behavior and actual device isolation before enabling the adapter.

Generated builds and simulator receipts remain in the normal build paths, not in this source package.

Invocation profiles reserve a durable cleanup entry before allocating a WebView. Partial native construction destroys the allocated view and retains a cold-start cleanup entry if the platform still has the profile loaded. Duplicate profile requests fail before allocation. Invocation windows also disable automatic/multiple windows and the native popup callback rejects them before allocating any default-profile temporary WebView; ordinary player popup behavior stays upstream.

## Offline edition transport boundary

The offline edition opts into a separate no-network browser policy. Android reserves
`maaso_offline_<32 lowercase hex>` profiles, requires both `MULTI_PROFILE` and
`DOCUMENT_START_SCRIPT`, blocks native network loads, and installs the trusted script
for all origins before navigation. Original `maaso_invocation_` and default-player
semantics remain unchanged. Cleanup recognizes both private profile namespaces.

On WebKit, `addOfflineDocumentStartScript` is an explicit Dart API for ephemeral
controllers. It installs a `WKUserScript` at document start with
`isForMainFrameOnly: false`; JavaScript-channel resets restore that policy after
awaiting script removal. No Pigeon wire contract changed.

The shared policy disables peer-connection, data-channel, WebTransport and related
WebRTC constructors in every frame, and seals same-origin iframe/document window
getters for synchronous child access. This supplements the host CSP and navigation
policy; it does not replace them or grant authored content native capabilities.
