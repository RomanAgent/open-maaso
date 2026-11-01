"""Source boundaries complement channel tests; they do not simulate device pixels."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

class GameSnapshotContract(unittest.TestCase):
    def test_ios_timeout_retains_physical_capture_until_matching_callback(self):
        source = (ROOT / 'ios/Runner/AppDelegate.swift').read_text()
        plugin = source.split('private final class MaasoGameSnapshotPlugin {', 1)[1].split('private final class MaasoSharePlugin', 1)[0]
        finish = plugin.split('let finish: (Data?) -> Void =', 1)[1].split('DispatchQueue.main.asyncAfter', 1)[0]
        self.assertNotIn('activeCapture = nil', finish)
        self.assertIn('DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finish(nil) }', plugin)
        callback = plugin.split('webView.takeSnapshot(with: configuration)', 1)[1]
        self.assertIn('self.activeCapture == captureID', callback)
        self.assertRegex(callback, r'defer\s*\{\s*if self.activeCapture == captureID \{ self.activeCapture = nil \}')
        self.assertIn('configuration.rect = webView.bounds', plugin)
        self.assertIn('UIApplication.shared.applicationState == .active', callback)
        self.assertIn('$0.count <= 256 * 1024', callback)
        self.assertNotIn('UIScreen.main', plugin)

    def test_android_only_draws_target_webview_and_drains_encoder(self):
        source = (ROOT / 'android/app/src/main/kotlin/com/futurpals/maaso/GameSnapshotPlugin.kt').read_text()
        self.assertIn('WebViewFlutterAndroidExternalApi.getWebView(engine, identifier)', source)
        self.assertIn('target.draw(canvas)', source)
        self.assertIn('view.windowToken == decor.windowToken', source)
        self.assertIn('activity.hasWindowFocus()', source)
        self.assertIn('640.0 / max(target.width, target.height)', source)
        self.assertIn('it.size <= 256 * 1024', source)
        self.assertIn('finally {\n                        snapshot.recycle()', source)
        reply = source.split('private fun reply(', 1)[1].split('private fun finishPhysical', 1)[0]
        self.assertNotIn('active = null', reply)
        self.assertIn('if (active !== capture) return', source)
        for forbidden in ['PixelCopy.request(', 'MediaProjectionManager', 'decor.draw(', 'rootView.draw(', 'startActivityForResult(']:
            self.assertNotIn(forbidden, source)

if __name__ == '__main__':
    unittest.main()
