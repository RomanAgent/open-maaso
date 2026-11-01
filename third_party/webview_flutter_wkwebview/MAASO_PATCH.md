# Maaso invocation isolation patch

Pinned upstream: `webview_flutter_wkwebview` `3.26.0`. `UPSTREAM_SOURCE.json` records the SHA-256 of each original copied file. Upstream LICENSE is retained. No pub-cache file is edited.

This fork adds an explicit opt-in data-container constructor before any authored document loads. The normal constructor remains unchanged. iOS/macOS use a fresh nonpersistent WKWebsiteDataStore per configuration; Android uses a per-invocation AndroidX WebView profile, requires MULTI_PROFILE support, and never falls back to the shared default profile.

Pigeon schema and checked-in Dart/native channel bindings receive the same narrow additions. Pigeon was not installed locally when this patch was prepared: wire bindings are updated following the pinned generated named-constructor pattern, rather than claiming a generator run. Validate the matching channel names, codec arguments, default-path behavior and actual device isolation before enabling the adapter.

Generated builds and simulator receipts remain in the normal build paths, not in this source package.
