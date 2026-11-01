"""Compile actual ASR dispatch methods against recording platform boundaries."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ.get('MAASO_REPO_ROOT', str(Path(__file__).resolve().parents[2])))

def function(source, marker):
    start = source.index(marker)
    at = source.index('{', start)
    depth = 1
    end = at + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

SWIFT = r'''
import Foundation
final class SFSpeechAudioBufferRecognitionRequest {
    var requiresOnDeviceRecognition = false
    var shouldReportPartialResults = false
    func append(_ buffer: Int) {}
}
final class SpeechResult {
    let bestTranscription = Transcription(); let isFinal = true
    final class Transcription { let formattedString = "recognized" }
}
final class Task { func cancel() {} }
final class SFSpeechRecognizer {
    static var available = true; static var local = true
    static var dispatched: [Bool] = []
    static var callback: ((SpeechResult?, Error?) -> Void)?
    init?(locale: Locale) {}
    var isAvailable: Bool { Self.available }
    var supportsOnDeviceRecognition: Bool { Self.local }
    func recognitionTask(with request: SFSpeechAudioBufferRecognitionRequest, resultHandler: @escaping (SpeechResult?, Error?) -> Void) -> Task {
        Self.dispatched.append(request.requiresOnDeviceRecognition)
        Self.callback = resultHandler
        return Task()
    }
}
final class AVAudioSession {
    enum Category { case record }; enum Mode { case measurement }
    struct Options: OptionSet { let rawValue: Int; static let duckOthers = Options(rawValue: 1); static let notifyOthersOnDeactivation = Options(rawValue: 2) }
    static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    func setCategory(_ category: Category, mode: Mode, options: Options) throws {}
    func setActive(_ value: Bool, options: Options) throws {}
}
final class Engine {
    final class Input {
        func outputFormat(forBus: Int) -> Int { 0 }
        func removeTap(onBus: Int) {}
        func installTap(onBus: Int, bufferSize: Int, format: Int, block: @escaping (Int, Int) -> Void) {}
    }
    let inputNode = Input(); var starts = 0
    func prepare() {}
    func start() throws { starts += 1 }
}
final class Harness {
    var activeRequestId: Int64?; var latestStartRequestId: Int64?
    var externalAudio = false; var shouldDeactivateAudioSessionOnCleanup = false
    var speechRecognizer: SFSpeechRecognizer?; var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?; var recognitionTask: Task?
    let audioEngine = Engine(); var callbacks = 0
    func emitCallback(_ type: String, requestId: Int64, value: Any) { callbacks += 1 }
    func finishRecognitionAfterFinal() {}
    func cleanupRecognition(deactivateAudioSession: Bool) {}
    func run(external: Bool = false) throws { try startRecognition(locale: "en-US", externalAudio: external, requestId: 7) }
    // ACTUAL_METHOD
}
for local in [false, true] {
    for external in [false, true] {
        SFSpeechRecognizer.available = true; SFSpeechRecognizer.local = local; SFSpeechRecognizer.dispatched = []
        let h = Harness(); var rejected = false
        do { try h.run(external: external) } catch { rejected = true }
        if !local {
            precondition(rejected && SFSpeechRecognizer.dispatched.isEmpty && h.audioEngine.starts == 0, "Unavailable device recognition reached audio/provider")
        } else {
            precondition(!rejected && SFSpeechRecognizer.dispatched == [true], "Recognizer request did not require local processing")
            precondition(h.audioEngine.starts == (external ? 0 : 1))
            h.activeRequestId = 8; let count = h.callbacks
            SFSpeechRecognizer.callback?(SpeechResult(), nil)
            precondition(h.callbacks == count && h.activeRequestId == 8, "Old callback touched a new request")
        }
    }
}
SFSpeechRecognizer.available = false; SFSpeechRecognizer.local = true; SFSpeechRecognizer.dispatched = []
do { try Harness().run(); preconditionFailure("Unavailable recognizer admitted") } catch {}
precondition(SFSpeechRecognizer.dispatched.isEmpty)
print("iOS actual ASR offline dispatch boundary passed")
'''

KOTLIN = r'''
import java.util.Locale
object Build { object VERSION { var SDK_INT = 31 }; object VERSION_CODES { const val S = 31 } }
object Manifest { object permission { const val RECORD_AUDIO = "record" } }
object PackageManager { const val PERMISSION_GRANTED = 0 }
class Bundle { fun getStringArrayList(key: String): ArrayList<String>? = null }
class Intent(val action: String) { fun putExtra(key: String, value: Any): Intent = this }
object RecognizerIntent { const val ACTION_RECOGNIZE_SPEECH="recognize"; const val EXTRA_LANGUAGE_MODEL="model"; const val LANGUAGE_MODEL_FREE_FORM="free"; const val EXTRA_LANGUAGE="language"; const val EXTRA_PARTIAL_RESULTS="partial" }
interface RecognitionListener {
    fun onReadyForSpeech(params: Bundle?); fun onBeginningOfSpeech(); fun onRmsChanged(value: Float); fun onBufferReceived(buffer: ByteArray?); fun onEndOfSpeech(); fun onError(error: Int); fun onResults(results: Bundle?); fun onPartialResults(results: Bundle?); fun onEvent(type: Int, params: Bundle?)
}
class SpeechRecognizer {
    companion object {
        var available = true; var failFactory = false; var failListening = false
        var ordinaryFactories = 0; var localFactories = 0; var starts = 0
        const val RESULTS_RECOGNITION = "results"
        fun isRecognitionAvailable(owner: Any) = true
        fun isOnDeviceRecognitionAvailable(owner: Any) = available
        fun createSpeechRecognizer(owner: Any): SpeechRecognizer { ordinaryFactories++; return SpeechRecognizer() }
        fun createOnDeviceSpeechRecognizer(owner: Any): SpeechRecognizer { localFactories++; if(failFactory) throw UnsupportedOperationException(); return SpeechRecognizer() }
        fun reset() { available=true; failFactory=false; failListening=false; ordinaryFactories=0; localFactories=0; starts=0; Build.VERSION.SDK_INT=31 }
    }
    fun cancel() {}; fun destroy() {}; fun setRecognitionListener(listener: RecognitionListener) {}
    fun startListening(intent: Intent) { if(failListening) throw IllegalStateException(); starts++ }
}
class MethodChannel { interface Result { fun success(value: Any?) } }
class Result: MethodChannel.Result { val values = mutableListOf<Any?>(); override fun success(value: Any?) { values.add(value) } }
open class Activity { open fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {} }
class Harness: Activity() {
    var pendingStartResult: MethodChannel.Result? = null; var pendingStartLocale: String? = null; var pendingStartRequestId: Long? = null
    var activeNativeAsrRequestId: Long? = null; var speechRecognizer: SpeechRecognizer? = null
    var permission = PackageManager.PERMISSION_GRANTED; var permissionRequests = 0; val errors = mutableListOf<String>()
    fun checkSelfPermission(name: String) = permission
    fun requestPermissions(names: Array<String>, code: Int) { permissionRequests++ }
    fun emitNativeAsrCallback(method: String, requestId: Long, value: Any) { if(method == "onError") errors.add(value.toString()) }
    fun run(result: MethodChannel.Result) { startNativeAsr("en-US", 7, result) }
    // ACTUAL_METHODS
}
fun main() {
    SpeechRecognizer.reset(); Build.VERSION.SDK_INT=30
    var h=Harness(); var result=Result(); h.run(result)
    check(result.values == listOf(false) && SpeechRecognizer.ordinaryFactories == 0 && SpeechRecognizer.localFactories == 0 && h.permissionRequests == 0) { "Old API reached provider" }
    SpeechRecognizer.reset(); SpeechRecognizer.available=false
    h=Harness(); result=Result(); h.run(result)
    check(result.values == listOf(false) && SpeechRecognizer.starts == 0 && h.errors.isNotEmpty())
    SpeechRecognizer.reset(); h=Harness(); result=Result(); h.run(result)
    check(result.values == listOf(true) && SpeechRecognizer.ordinaryFactories == 0 && SpeechRecognizer.localFactories == 1 && SpeechRecognizer.starts == 1)
    SpeechRecognizer.reset(); h=Harness(); h.permission=1; result=Result(); h.run(result)
    check(result.values.isEmpty() && h.permissionRequests == 1)
    SpeechRecognizer.available=false
    h.onRequestPermissionsResult(9012, arrayOf("record"), intArrayOf(0))
    check(result.values == listOf(false) && SpeechRecognizer.starts == 0) { "Availability changed during permission await" }
    SpeechRecognizer.reset(); h=Harness(); h.permission=1; result=Result(); h.run(result)
    h.pendingStartResult=null; h.pendingStartRequestId=null; h.pendingStartLocale=null
    h.onRequestPermissionsResult(9012, arrayOf("record"), intArrayOf(0))
    check(SpeechRecognizer.localFactories == 0 && SpeechRecognizer.starts == 0) { "Cancelled request restarted" }
    for (atFactory in listOf(true,false)) {
        SpeechRecognizer.reset(); SpeechRecognizer.failFactory=atFactory; SpeechRecognizer.failListening=!atFactory
        h=Harness(); result=Result(); h.run(result)
        check(result.values == listOf(false) && h.activeNativeAsrRequestId == null && h.errors.isNotEmpty()) { "Device recognizer failure was reported as success" }
    }
    println("Android actual ASR offline and permission fence passed")
}
'''

class NativeAsrOfflineTest(unittest.TestCase):
    def test_ios_actual_dispatch(self):
        text=(ROOT/'ios/Runner/AppDelegate.swift').read_text().split('final class NativeAsrPlugin',1)[1]
        method=function(text,'private func startRecognition(')
        with tempfile.TemporaryDirectory(prefix='maaso-asr-swift-') as temp:
            folder=Path(temp); source=folder/'asr.swift'; source.write_text(SWIFT.replace('// ACTUAL_METHOD',method))
            build=subprocess.run(['xcrun','swiftc','-module-cache-path',str(folder/'cache'),str(source),'-o',str(folder/'test')],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stderr)
            run=subprocess.run([str(folder/'test')],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)

    def test_android_actual_dispatch_and_permission_callback(self):
        text=(ROOT/'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt').read_text()
        methods='\n'.join(function(text,marker) for marker in ['private fun startNativeAsr(','private fun startRecognizer(','override fun onRequestPermissionsResult('])
        cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
        coordinates=[('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.2.20'),('org.jetbrains.kotlin','kotlin-stdlib','2.2.20'),('org.jetbrains.kotlin','kotlin-script-runtime','2.2.20'),('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),('org.jetbrains.kotlin','kotlin-daemon-embeddable','2.2.20'),('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0'),('org.jetbrains','annotations','13.0')]
        jars=[]
        for group,name,version in coordinates:
            found=list((cache/group/name/version).glob('*/*.jar'))
            if not found: self.skipTest(f'Cached native compiler dependency missing: {name}/{version}')
            jars.append(str(found[0]))
        cp=os.pathsep.join(jars)
        with tempfile.TemporaryDirectory(prefix='maaso-asr-kotlin-') as temp:
            folder=Path(temp); source=folder/'Asr.kt'; source.write_text(KOTLIN.replace('// ACTUAL_METHODS',methods))
            build=subprocess.run(['java','-cp',cp,'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',cp,'-d',str(folder/'classes'),str(source)],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stderr)
            run=subprocess.run(['java','-cp',str(folder/'classes')+os.pathsep+cp,'AsrKt'],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)

if __name__ == '__main__': unittest.main()
