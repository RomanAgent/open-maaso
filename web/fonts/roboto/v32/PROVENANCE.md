# Local Flutter web fallback font

Unmodified Roboto WOFF2 downloaded from the exact official Google Fonts URL referenced by Flutter 3.47.2's web engine:

https://fonts.gstatic.com/s/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2

SHA-256: `35b02ca266b79eb4996590f15817425a1ce9ebf48f84471843233ff614656bf2`

Retains the Roboto license notice distributed with that Flutter SDK. `web/flutter_bootstrap.js` changes only the base URL to `fonts/`, so this copy is served by the app itself, not the Google CDN. Native platform font selection is unchanged.
