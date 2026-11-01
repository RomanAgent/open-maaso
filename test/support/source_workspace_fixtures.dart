import 'dart:convert';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';

const workspaceFixtureHtml =
    '<main><p id="score">0</p><button id="play">Play</button><button id="restart">Restart</button></main>';
const workspaceFixtureJs =
    'let score=0;const label=document.getElementById("score");function render(){label.textContent=String(score);}document.getElementById("play").addEventListener("click",()=>{score++;render();});document.getElementById("restart").addEventListener("click",()=>{score=0;render();});render();';
const workspaceFixtureCss = 'main{min-height:100vh}button{min-height:48px}';

Map<String, Object?> workspaceFixtureManifest() => {
  'schemaVersion': 2,
  'events': <Object>[],
  'instructions': 'Change the local score through configure',
  'actions': [
    {
      'name': 'configure',
      'schema': {
        'type': 'object',
        'properties': {
          'value': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        },
        'required': ['value'],
        'additionalProperties': false,
      },
      'risk': 'localMutation',
      'consequencePolicy': 'reversible',
    },
  ],
};
String workspaceFixturePlan({
  bool game = true,
  String title = 'Scoped Gomoku',
  String summary = 'All requested source generated; verification remains.',
  String instructions = 'Play scores and restart resets.',
}) => jsonEncode({
  'title': title,
  'summary': summary,
  'skillInstructions': instructions,
  'interfaces': 'page owns score/play/restart IDs; logic owns the score',
  'files': [
    {'id': 'page', 'kind': 'html', 'purpose': 'All requested screens'},
    {'id': 'style', 'kind': 'css', 'purpose': 'The requested presentation'},
    {
      'id': 'logic',
      'kind': 'js',
      'purpose': 'All requested gameplay and controls',
      'dependsOn': ['page', 'style'],
    },
  ],
  if (!game) 'manifest': workspaceFixtureManifest(),
  'done': true,
});
String workspaceFixtureChunk(
  String fileId,
  String append, {
  String prefix = '',
  bool done = true,
}) => jsonEncode({
  'fileId': fileId,
  'baseCursor': utf8.encode(prefix).length,
  'prefixHash': sourceWorkspaceDigest(prefix),
  'append': append,
  'done': done,
});
List<String> workspaceFixtureResponses({
  bool game = true,
  String title = 'Scoped Gomoku',
  String html = workspaceFixtureHtml,
  String css = workspaceFixtureCss,
  String js = workspaceFixtureJs,
  String summary = 'All requested source generated; verification remains.',
  String instructions = 'Play scores and restart resets.',
}) => [
  workspaceFixturePlan(
    game: game,
    title: title,
    summary: summary,
    instructions: instructions,
  ),
  workspaceFixtureChunk('page', html),
  workspaceFixtureChunk('style', css),
  workspaceFixtureChunk(
    'logic',
    !game && js == workspaceFixtureJs
        ? '$js Surface.onAgent("configure",data=>{score=data.value;render();});'
        : js,
  ),
];
