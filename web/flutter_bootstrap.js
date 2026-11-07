{{flutter_js}}
{{flutter_build_config}}

// Package the renderer with the app; never fetch Flutter's engine from a CDN.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
    fontFallbackBaseUrl: "fonts/",
  },
});
