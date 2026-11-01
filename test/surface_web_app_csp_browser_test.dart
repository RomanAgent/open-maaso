import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime_diagnostic.dart';
import 'package:maaso/src/features/agent/application/surface/surface_web_app_host.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace_assembly.dart';

// Run real browser policy and cross-origin loading, not a CSP string imitation.
void main() {
  final executable = Platform.environment['MAASO_CSP_BROWSER_EXECUTABLE'];
  test(
    'ordinary Web libraries, modules, media and polyfills run across origins',
    () async {
      final profile = await Directory.systemTemp.createTemp(
        'maaso-web-resources-',
      );
      final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final assets = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${host.port}';
      final external = 'http://127.0.0.1:${assets.port}';
      final requests = <String>[];
      final project = SurfaceProject.fromJson({
        'id': 'web-resources-browser',
        'title': 'Web resources',
        'kind': 'fullscreen',
        'rendering': 'webApp',
        'experienceType': 'utility',
        'html':
            '''
<link rel="stylesheet" href="$external/style.css">
<script src="$external/library.js"></script>
<script type="module">import {value} from '$external/module.js';window.moduleValue=value;</script>
<button id="play" onclick="play()">Play</button><pre id="result"></pre>
''',
        'css':
            "@import url('$external/import.css'); #play{background-image:url('$external/image.svg')}",
        'js':
            '''
function play(){document.body.dataset.played='yes';}
const result={library:window.libraryValue,host:typeof window.Surface.emit==='function'};
document.getElementById('play').click();
result.handler=document.body.dataset.played==='yes';
result.eval=eval('6*7')===42;
result.dynamicFunction=new Function('return 42')()===42;
Array.prototype.webExample=function(){return this.length;};
result.polyfill=[1,2].webExample()===2;delete Array.prototype.webExample;
const dynamic=document.createElement('script');
dynamic.textContent='window.dynamicValue=42;';document.body.append(dynamic);
result.dynamicInline=window.dynamicValue===42;
const workerUrl=URL.createObjectURL(new Blob(['postMessage(42)'],{type:'text/javascript'}));
const worker=new Worker(workerUrl);
const workerDone=new Promise(resolve=>{worker.onmessage=e=>{result.worker=e.data===42;worker.terminate();URL.revokeObjectURL(workerUrl);resolve();};});
const image=new Image();
const imageDone=new Promise(resolve=>{image.onload=()=>{result.image=image.naturalWidth===2;resolve();};image.onerror=resolve;});
image.src='$external/image.svg';document.body.append(image);
const frame=document.createElement('iframe');frame.src='$external/frame.html';document.body.append(frame);
const apiDone=fetch('$external/api').then(r=>r.json()).then(v=>result.fetch=v.value===42);
const moduleDone=import('$external/module.js').then(m=>result.dynamicModule=m.value===42);
Promise.all([apiDone,moduleDone,imageDone,workerDone]).then(()=>setTimeout(()=>{
 result.module=window.moduleValue===42;
 result.css=getComputedStyle(document.getElementById('play')).color==='rgb(17, 34, 51)';
 result.importedCss=getComputedStyle(document.body).getPropertyValue('--external').trim()==='ready';
 document.getElementById('result').textContent=JSON.stringify(result);
},200));
setTimeout(()=>{missingOwnedRuntimeSymbol();},800);
setTimeout(()=>{const out=JSON.parse(document.getElementById('result').textContent);out.diagnostic=window.observations.filter(x=>x.diagnostic).map(x=>x.diagnostic).pop();document.getElementById('result').textContent=JSON.stringify(out);},1200);
''',
        'manifest': {'actions': [], 'events': []},
      });
      final source = SurfaceWebAppHost.build(project, lifecycleToken: 7)
          .replaceFirst(
            '<head>',
            '<head><script>window.observations=[];window.SurfaceValidationLifecycle={postMessage:function(value){window.observations.push(JSON.parse(value));}};</script>',
          );
      final assetSubscription = assets.listen((request) async {
        requests.add(request.uri.path);
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        switch (request.uri.path) {
          case '/library.js':
            request.response.headers.contentType = ContentType(
              'application',
              'javascript',
            );
            request.response.write('window.libraryValue=42;');
          case '/module.js':
            request.response.headers.contentType = ContentType(
              'application',
              'javascript',
            );
            request.response.write('export const value=42;');
          case '/style.css':
            request.response.headers.contentType = ContentType('text', 'css');
            request.response.write('#play{color:rgb(17,34,51)}');
          case '/import.css':
            request.response.headers.contentType = ContentType('text', 'css');
            request.response.write('body{--external:ready}');
          case '/image.svg':
            request.response.headers.contentType = ContentType(
              'image',
              'svg+xml',
            );
            request.response.write(
              '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2" fill="red"/></svg>',
            );
          case '/frame.html':
            request.response.headers.contentType = ContentType.html;
            request.response.write('<button>Embedded game</button>');
          case '/api':
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"value":42}');
          default:
            request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final hostSubscription = host.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(source);
        await request.response.close();
      });
      Process? browser;
      try {
        browser = await Process.start(executable!, [
          '--headless=new',
          '--disable-gpu',
          '--disable-extensions',
          '--disable-background-networking',
          '--disable-component-update',
          '--disable-sync',
          '--metrics-recording-only',
          '--disable-default-apps',
          '--use-mock-keychain',
          '--password-store=basic',
          '--no-first-run',
          '--no-default-browser-check',
          '--no-proxy-server',
          '--user-data-dir=${profile.path}',
          '--dump-dom',
          '--virtual-time-budget=5000',
          origin,
        ]);
        final stdoutFuture = browser.stdout.transform(utf8.decoder).join();
        final stderrFuture = browser.stderr.transform(utf8.decoder).join();
        final exit = await browser.exitCode.timeout(
          const Duration(seconds: 30),
        );
        final output = await stdoutFuture;
        final errors = await stderrFuture;
        expect(exit, 0, reason: errors);
        final resultText = html.parse(output).querySelector('#result')?.text;
        expect(resultText, isNotEmpty, reason: errors);
        final evidence = jsonDecode(resultText!) as Map<String, dynamic>;
        expect(evidence['library'], 42);
        expect(evidence['diagnostic'], isA<Map>());
        final diagnostic = SurfaceRuntimeDiagnostic.tryParse(
          evidence['diagnostic'],
        );
        expect(diagnostic, isNotNull);
        expect(diagnostic!.category, 'reference_error');
        final offset = diagnostic.sourceOffset(project.js);
        expect(offset, isNotNull);
        expect(
          project.js.substring(offset!),
          startsWith('missingOwnedRuntimeSymbol'),
        );

        for (final feature in [
          'host',
          'handler',
          'eval',
          'dynamicFunction',
          'polyfill',
          'dynamicInline',
          'worker',
          'image',
          'fetch',
          'dynamicModule',
          'module',
          'css',
          'importedCss',
        ]) {
          expect(evidence[feature], isTrue, reason: '$feature: $evidence');
        }
        for (final path in [
          '/library.js',
          '/module.js',
          '/style.css',
          '/import.css',
          '/image.svg',
          '/frame.html',
          '/api',
        ]) {
          expect(requests, contains(path));
        }
      } finally {
        browser?.kill();
        await hostSubscription.cancel();
        await assetSubscription.cancel();
        await host.close(force: true);
        await assets.close(force: true);
        if (await profile.exists()) await profile.delete(recursive: true);
      }
    },
    skip: executable == null
        ? 'Set MAASO_CSP_BROWSER_EXECUTABLE to run browser resource integration.'
        : false,
  );
  test(
    'owned relative modules, export-from, cycles and scoped vendors run in the browser',
    () async {
      final profile = await Directory.systemTemp.createTemp(
        'maaso-owned-modules-',
      );
      final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final assets = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final external = 'http://127.0.0.1:${assets.port}';
      final requests = <String>[];
      final importMap = {
        'imports': {'vendor': '$external/wrong-vendor.js'},
        'scopes': {
          './': {'vendor': '$external/vendor.js'},
        },
      };
      final sources = <String, String>{
        'index.html':
            '<!doctype html><html><head><script type="importmap">${jsonEncode(importMap)}</script></head><body><pre id="result">PENDING</pre><script type="module" src="game.js"></script></body></html>',
        'game.js':
            '''
import {deep} from './lib.js';
import {cycleValue} from './cycle-a.js';
import {vendor} from 'vendor';
import {remote} from '$external/module.js';
const again=await import('./leaf.js');
document.getElementById('result').textContent=JSON.stringify({
  deep:deep+again.deep,cycle:cycleValue,vendor,remote,loads:window.leafLoads,
  host:typeof window.Surface.emit==='function'
});
''',
        'lib.js': "export {deep} from './leaf.js';",
        'leaf.js':
            'window.leafLoads=(window.leafLoads||0)+1;export const deep=21;',
        'cycle-a.js':
            "import {readB} from './cycle-b.js';export function readA(){return 1;}export const cycleValue=readB();",
        'cycle-b.js':
            "import {readA} from './cycle-a.js';export function readB(){return readA()+1;}",
      };
      final plans = [
        for (final id in sources.keys)
          SourceFilePlan(
            id: id,
            kind: id.endsWith('.html')
                ? SourceFileKind.html
                : SourceFileKind.js,
            purpose: 'Module fixture',
          ),
      ];
      final workspace = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest('ordinary module fixture'),
        experienceType: 'utility',
        blueprintComplete: true,
        blueprint: SourceBlueprint(
          title: 'Modules',
          summary: 'Browser modules',
          skillInstructions: 'Open',
          files: plans,
        ),
        files: [
          for (final plan in plans)
            SourceFileSnapshot(
              plan: plan,
              source: sources[plan.id]!,
              complete: true,
            ),
        ],
      );
      final original = jsonEncode(workspace.toJson());
      final assembly = SourceWorkspaceAssembly.fromWorkspace(workspace);
      expect(jsonEncode(workspace.toJson()), original);
      expect(assembly.js, isEmpty);
      expect(assembly.javaScriptFileIds, isEmpty);
      final parsed = html.parse(assembly.html);
      expect(parsed.querySelectorAll('script[type="importmap"]'), hasLength(1));
      final merged =
          jsonDecode(parsed.querySelector('script[type="importmap"]')!.text)
              as Map;
      expect((merged['imports'] as Map)['vendor'], '$external/wrong-vendor.js');
      expect(merged['scopes'], importMap['scopes']);
      expect(parsed.querySelectorAll('script[src]'), hasLength(1));
      expect(parsed.querySelector('script[src]')!.attributes['type'], 'module');
      final compiled = Uri.parse(
        parsed.querySelector('script[src]')!.attributes['src']!,
      ).data!.contentAsString(encoding: utf8);
      expect(compiled, contains("from '$external/module.js'"));
      expect(compiled, contains('from "$external/vendor.js"'));
      expect(compiled, isNot(contains('from "$external/wrong-vendor.js"')));
      final project = SurfaceProject.fromJson({
        'id': 'owned-modules-browser',
        'title': 'Owned modules',
        'kind': 'fullscreen',
        'rendering': 'webApp',
        'experienceType': 'utility',
        'html': assembly.html,
        'css': assembly.css,
        'js': assembly.js,
        'manifest': {'actions': [], 'events': []},
      });
      final source = SurfaceWebAppHost.build(project, lifecycleToken: 11)
          .replaceFirst(
            '<head>',
            '<head><script>window.addEventListener("error",e=>document.getElementById("result").textContent="ERROR:"+e.message);</script>',
          );
      final assetSubscription = assets.listen((request) async {
        requests.add(request.uri.path);
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.headers.contentType = ContentType(
          'application',
          'javascript',
        );
        request.response.write(switch (request.uri.path) {
          '/vendor.js' => 'export const vendor=5;',
          '/wrong-vendor.js' => 'export const vendor=99;',
          '/module.js' => 'export const remote=6;',
          _ => 'throw Error("unexpected module");',
        });
        await request.response.close();
      });
      final hostSubscription = host.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(source);
        await request.response.close();
      });
      Process? browser;
      try {
        browser = await Process.start(executable!, [
          '--headless=new',
          '--disable-gpu',
          '--disable-extensions',
          '--disable-background-networking',
          '--disable-component-update',
          '--disable-sync',
          '--metrics-recording-only',
          '--disable-default-apps',
          '--use-mock-keychain',
          '--password-store=basic',
          '--no-first-run',
          '--no-default-browser-check',
          '--no-proxy-server',
          '--user-data-dir=${profile.path}',
          '--dump-dom',
          '--virtual-time-budget=4000',
          'http://127.0.0.1:${host.port}',
        ]);
        final out = browser.stdout.transform(utf8.decoder).join();
        final errors = browser.stderr.transform(utf8.decoder).join();
        final exit = await browser.exitCode.timeout(
          const Duration(seconds: 30),
        );
        final output = await out;
        final stderr = await errors;
        expect(exit, 0, reason: stderr);
        final text = html.parse(output).querySelector('#result')?.text;
        expect(text, isNot('PENDING'), reason: stderr);
        expect(text, isNot(startsWith('ERROR:')), reason: stderr);
        expect(jsonDecode(text!), {
          'deep': 42,
          'cycle': 2,
          'vendor': 5,
          'remote': 6,
          'loads': 1,
          'host': true,
        });
        expect(requests, containsAll(['/vendor.js', '/module.js']));
        expect(requests, isNot(contains('/wrong-vendor.js')));
      } finally {
        browser?.kill();
        await hostSubscription.cancel();
        await assetSubscription.cancel();
        await host.close(force: true);
        await assets.close(force: true);
        if (await profile.exists()) await profile.delete(recursive: true);
      }
    },
    skip: executable == null
        ? 'Set MAASO_CSP_BROWSER_EXECUTABLE for real module integration.'
        : false,
  );
}
