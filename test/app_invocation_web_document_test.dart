import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_web_document.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';

final _origin =
    Platform.environment['MAASO_INVOCATION_PROBE_ORIGIN'] ??
    'http://127.0.0.1:18765';
const _source = r'''
document.querySelector('#manual').addEventListener('click',()=>{
  document.querySelector('#value').textContent='manual control';
});
Surface.registerInvocation({version:1,actions:{
  'dom.configure':async args=>{
    const response=await fetch('__PROBE_ORIGIN__/data.json');
    const remote=await response.json();
    document.querySelector('#value').textContent=args.text;
    localStorage.setItem('invocation-value',args.text);
    return {text:args.text,remote:remote.value};
  },
  'dom.read':()=>({
    text:document.querySelector('#value').textContent,
    classic:window.externalClassic,module:window.externalModule,
    stored:localStorage.getItem('invocation-value'),
    nativeChannel:typeof window.MaasoInvocationBridge,
    color:getComputedStyle(document.querySelector('#value')).color,
  }),
  'dom.empty':()=>{document.querySelector('#value').textContent='visible only';},
  'dom.image':()=>{
    const canvas=document.createElement('canvas');canvas.width=2;canvas.height=2;
    const context=canvas.getContext('2d');context.fillStyle='#ff0000';context.fillRect(0,0,2,2);
    return canvas;
  },
  'dom.delay':async()=>{await new Promise(resolve=>setTimeout(resolve,100));return {async:true};},
  'dom.tooLarge':()=>({text:'x'.repeat(65537)}),
}});
''';

SurfaceProject _project({String rendering = 'webApp'}) =>
    SurfaceProject.fromJson({
      'id': 'dom-invocation-probe',
      'title': 'DOM invocation probe',
      'rendering': rendering,
      'experienceType': 'utility',
      'html':
          '''<!doctype html><html lang="en"><head>
<script src="$_origin/dependency.js"></script>
<script type="module" src="$_origin/module.js"></script>
<link rel="stylesheet" href="$_origin/remote.css">
</head><body data-probe="kept"><main>
<p id="value">original</p><button id="manual">Manual control</button>
</main></body></html>''',
      'css': "body{font-family:system-ui} #value::after{content:'</style>'}",
      'js': _source.replaceAll('__PROBE_ORIGIN__', _origin),
      'manifest': {
        'schemaVersion': 2,
        'actions': [
          for (final name in [
            'dom.configure',
            'dom.read',
            'dom.empty',
            'dom.image',
            'dom.delay',
            'dom.tooLarge',
          ])
            {
              'name': name,
              'schema': {
                'type': 'object',
                'properties': {
                  if (name == 'dom.configure')
                    'text': {'type': 'string', 'maxLength': 128},
                },
                'required': [if (name == 'dom.configure') 'text'],
                'additionalProperties': false,
              },
              'risk': 'localMutation',
              'consequencePolicy': 'reversible',
            },
        ],
      },
    });

String _build(SurfaceProject project) => AppInvocationWebDocument.build(
  source: project,
  descriptor: AppInvocationDescriptor.fromSurface(
    project: project,
    identity: AppInvocationIdentity(
      scopeKey: 'probe|owner',
      sourceId: project.id,
      revisionId: 'web-v1',
      sourceDigest: sha256
          .convert(utf8.encode(jsonEncode(project.toJson())))
          .toString(),
    ),
  ),
);

void main() {
  test(
    'mounts complete DOM, modules, dependencies and exact authored resources',
    () {
      for (final rendering in ['webApp', 'dom']) {
        final project = _project(rendering: rendering);
        final original = jsonEncode(project.toJson());
        final document = html.parse(_build(project));
        expect(document.body!.attributes['data-probe'], 'kept');
        expect(document.querySelector('#manual'), isNotNull);
        expect(
          document.querySelector('script[type="module"]')!.attributes['src'],
          '$_origin/module.js',
        );
        expect(
          document.querySelector('script[src="$_origin/dependency.js"]'),
          isNotNull,
        );
        expect(
          document.querySelector('link[href="$_origin/remote.css"]'),
          isNotNull,
        );
        final script = document
            .querySelector('script[src^="data:"]')!
            .attributes['src']!;
        expect(utf8.decode(base64Decode(script.split(',').last)), project.js);
        final style = document
            .querySelector('link[href^="data:"]')!
            .attributes['href']!;
        expect(utf8.decode(base64Decode(style.split(',').last)), project.css);
        final headScripts = document.head!.querySelectorAll('script');
        expect(headScripts[1].attributes['data-maaso-invocation'], '1');
        expect(headScripts[2].attributes['src'], '$_origin/dependency.js');
        expect(jsonEncode(project.toJson()), original);
      }
    },
  );

  test('exports the production browser document for browser and WK probes', () {
    final project = _project();
    final document = _build(project);
    final directory = Directory(
      Platform.environment['MAASO_INVOCATION_PROBE_DIRECTORY'] ??
          'build/verification/home-app-invocation/web-probe',
    )..createSync(recursive: true);
    File('${directory.path}/document.html').writeAsStringSync(document);
    File('${directory.path}/delayed-document.html').writeAsStringSync(
      _build(
        SurfaceProject.fromJson({
          ...project.toJson(),
          'js': '''window.addEventListener('load',()=>setTimeout(()=>{
Surface.onAgent=(name,args)=>({name,text:args.text});
},200));''',
        }),
      ),
    );
    File(
      '${directory.path}/dependency.js',
    ).writeAsStringSync('window.externalClassic = "classic loaded";');
    File('${directory.path}/module.js').writeAsStringSync(
      'await Promise.resolve(); window.externalModule = "module loaded"; export const loaded = true;',
    );
    File(
      '${directory.path}/remote.css',
    ).writeAsStringSync('#value{color:rgb(12, 34, 56)}');
    File(
      '${directory.path}/data.json',
    ).writeAsStringSync('{"value":"remote loaded"}');
    File('${directory.path}/source-identity.json').writeAsStringSync(
      jsonEncode({
        'sourceSha256': sha256
            .convert(utf8.encode(jsonEncode(project.toJson())))
            .toString(),
        'documentSha256': sha256.convert(utf8.encode(document)).toString(),
        'adapterVersion': 2,
      }),
    );
    expect(document, contains('data-maaso-invocation="1"'));
  });
}
