import 'dart:convert';

import 'package:maaso/src/features/agent/application/surface/surface_authoring_theme.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

import 'package:maaso/src/features/surface_play/domain/surface_play_agent_document.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';

/// Explicit, playable conformance examples. These are not evidence that a model
/// generated a novel project or that a candidate passed runtime verification.
abstract final class SurfacePlayExampleFactory {
  static ValidatedProjectBundleV2 build({
    required String projectId,
    required String revisionId,
    required String contentManifestId,
    required String requirementDigest,
    required String rulesId,
    Map<String, Object?>? config,
  }) {
    final rules =
        config ??
        switch (rulesId) {
          'gomoku.v1' => {'boardSize': 15, 'winLength': 5},
          'cooperative-switches.v1' => {'switchesPerRole': 2, 'goalMask': 15},
          'cooperative-dodge.v1' => cooperativeDodgeConfig,
          _ => {'cardsPerRole': 3},
        };
    final protocol = SurfacePlayProtocol.trustedGame(
      projectId: projectId,
      revisionId: revisionId,
      rulesId: rulesId,
      config: rules,
    );
    final title = switch (rulesId) {
      'gomoku.v1' => '一起下五子棋',
      'cooperative-switches.v1' => '双人开关谜题',
      'cooperative-dodge.v1' => '一起接星星',
      _ => '暗牌对决',
    };
    final summary = switch (rulesId) {
      'gomoku.v1' => '轮流落子，先连成目标数量的一方获胜。',
      'cooperative-switches.v1' => '各自控制两枚开关，一起把状态调到目标。',
      'cooperative-dodge.v1' => '两人各接到三颗自己的星星，同时避开落下的障碍。',
      _ => '各自秘密选牌，都选定后公开结果。',
    };
    const canonical = ProjectJsonCanonicalizer();
    final protocolJson = canonical.canonicalize(protocol.toJson());
    final agent = buildSurfacePlayAgentDocument(
      protocol: protocol,
      contentManifestId: contentManifestId,
      protocolSha256: surfaceProtocolDigest(protocolJson),
    );
    final project = {
      'packageSchema': 2,
      'profile': projectBundleV2Profile,
      'projectId': projectId,
      'revisionId': revisionId,
      'contentManifestId': contentManifestId,
      'projectKind': 'game',
      'entryPoint': 'dist/index.html',
      'agentProtocolVersion': 2,
      'sdkVersion': projectBundleV2RuntimeVersion,
      'runtimeMinVersion': projectBundleV2RuntimeVersion,
      'toolchainVersion': projectBundleV2ToolchainVersion,
      'title': title,
      'summary': summary,
    };
    const emptyParameters = {
      'type': 'object',
      'properties': <String, Object?>{},
      'required': <String>[],
      'additionalProperties': false,
    };
    final routes = {
      'schemaVersion': 2,
      'projectId': projectId,
      'revisionId': revisionId,
      'entryRouteId': 'game',
      'routes': [
        {
          'routeId': 'game',
          'parentRouteId': null,
          'title': title,
          'parametersSchema': emptyParameters,
          'backTarget': null,
          'retainState': true,
        },
        if (!protocol.isRealtime)
          {
            'routeId': 'rules',
            'parentRouteId': 'game',
            'title': '玩法说明',
            'parametersSchema': emptyParameters,
            'backTarget': 'game',
            'retainState': true,
          },
      ],
    };
    final js = protocol.isRealtime
        ? _realtimeSource
        : _source(title, summary, rulesId);
    final css =
        '${SurfaceAuthoringTheme.cssSnapshot()}\n'
        '${protocol.isRealtime ? _realtimeCss : _css}';
    final html =
        '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<title>${const HtmlEscape().convert(title)}</title><style>$css</style></head>'
        '<body><div id="maaso-project-root"></div><script>$js</script></body></html>';
    final playSteps = <Map<String, Object?>>[];
    void play(String seat, Map<String, Object?> args) => playSteps.add({
      'play': {'seatId': seat, 'args': args},
    });
    if (rulesId == 'gomoku.v1') {
      final length = rules['winLength']! as int;
      for (var i = 0; i < length; i++) {
        play('player1', {'x': i, 'y': 0});
        if (i < length - 1) play('player2', {'x': i, 'y': 1});
      }
    } else if (rulesId == 'cooperative-switches.v1') {
      final count = rules['switchesPerRole']! as int,
          goal = rules['goalMask']! as int;
      for (var i = 0; i < count * 2; i++) {
        if ((goal & (1 << i)) != 0) {
          play(i < count ? 'player1' : 'player2', {'switch': i});
        }
      }
    } else if (protocol.isRealtime) {
      play('player1', {});
      for (var window = 0; window < 3; window++) {
        for (final seat in ['player1', 'player2']) {
          play(seat, {
            'policy': 'collect',
            'windowId': 'window-$window',
            'validThroughTick': (window + 1) * 150,
            'durationTicks': 150,
          });
        }
        playSteps.add({'advanceTicks': 150});
      }
    } else {
      play('player1', {'card': 0});
      play('player2', {'card': 1});
    }
    final acceptance = {
      'schemaVersion': 1,
      'cases': [
        {
          'id': 'complete-real-match',
          'steps': playSteps,
          'expect': [
            {'path': 'visibleState.phase', 'equals': 'ended'},
          ],
        },
        if (!protocol.isRealtime)
          {
            'id': 'rules-route',
            'steps': [
              {'routeId': 'rules', 'params': <String, Object?>{}},
            ],
            'expect': [
              {'path': 'routeId', 'equals': 'rules'},
            ],
          },
      ],
    };
    final content = <String, String>{
      'project.json': canonical.canonicalize(project),
      'agent.protocol.json': protocolJson,
      'agent.md': agent,
      'routes.json': canonical.canonicalize(routes),
      'tests/acceptance.json': canonical.canonicalize(acceptance),
      'src/main.js': js,
      'src/styles.css': css,
      'dist/index.html': html,
    };
    final files = [
      for (final entry in content.entries)
        ProjectBundleV2File(
          path: entry.key,
          mimeType: entry.key.endsWith('.json')
              ? 'application/json'
              : entry.key.endsWith('.md')
              ? 'text/markdown'
              : entry.key.endsWith('.js')
              ? 'text/javascript'
              : entry.key.endsWith('.css')
              ? 'text/css'
              : 'text/html',
          role: entry.key.startsWith('dist/')
              ? ProjectBundleV2FileRole.runtime
              : ProjectBundleV2FileRole.source,
          bytes: utf8.encode(entry.value),
        ),
    ];
    final manifest = ProjectBundleV2Manifest.create(
      projectId: projectId,
      revisionId: revisionId,
      contentManifestId: contentManifestId,
      requirementRevision: 1,
      requirementDigest: requirementDigest,
      baseRevision: null,
      projectKind: 'game',
      files: files.map((file) => file.metadata),
    );
    return const ProjectBundleV2Codec().verify(manifest, files);
  }

  static String _source(String title, String summary, String rulesId) =>
      '''
(() => {
'use strict';
const title=${jsonEncode(title)}, summary=${jsonEncode(summary)}, rulesId=${jsonEncode(rulesId)};
let observation=Maaso.playObserve(), busy=false, error='', boardRoot=null, pendingRequest=null;
const element=(tag,text,cls)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;};
function legal(args){if(pendingRequest!==null)return null;return observation?.legalActions.find(action=>JSON.stringify(action.args)===JSON.stringify(args));}
function status(){
 if(!observation)return '玩法运行时未就绪';
 if(observation.phase==='paused')return '游戏已暂停';
 const state=observation.allowedView;
 if(state.phase==='ended')return state.teamWon?'合作成功！':state.reveal?(state.reveal.winner===0?'这局平手':('玩家 '+state.reveal.winner+' 获胜')):state.winner?('玩家 '+state.winner+' 获胜'):'这局平手';
 if(state.phase==='waiting')return '你已选牌，等待公开结果';
 return observation.legalActions.length?'轮到你操作':'等待另一位玩家';
}
async function submit(args){
 const action=legal(args);if(!action||busy)return;
 busy=true;error='';renderBoard();
 const requestId='r_'+Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
 const command={requestId,observationId:observation.observationId,actionId:action.actionId,args:action.args,
  expectedDecisionRevision:observation.decisionRevision,expectedTurnId:observation.turnId,actionToken:action.actionToken};
 try {
  const receipt=await Maaso.playSubmit(command);
  if(receipt.status==='pending'){pendingRequest=requestId;error='正在确认这一步，请勿重复提交';}
  else if(receipt.status!=='applied'&&receipt.status!=='duplicate')error='局面已变化，请按最新状态重试';
  observation=Maaso.playObserve();
 } catch (_) {pendingRequest=requestId;error='这一步未能确认，请先查询回执';}
 finally {busy=false;renderBoard();}
}
async function confirmPending(){
 if(busy||pendingRequest===null)return;busy=true;renderBoard();
 try {
  const receipt=await Maaso.playReceipt(pendingRequest);
  if(receipt===null){pendingRequest=null;error='这一步尚未提交，可按最新局面重试';}
  else if(receipt.status==='applied'||receipt.status==='duplicate'){pendingRequest=null;error='';}
  else error='这一步仍未确认，请稍后查询';
  observation=Maaso.playObserve();
 } catch (_) {error='暂时无法查询回执，请稍后确认';}
 finally {busy=false;renderBoard();}
}
function renderBoard(){
 if(!boardRoot)return;
 boardRoot.replaceChildren();
 const banner=element('p',busy?'正在确认操作':status(),'status');banner.setAttribute('role','status');boardRoot.append(banner);
 if(error){const warning=element('p',error,'maaso-error');warning.setAttribute('role','alert');boardRoot.append(warning);}
 if(pendingRequest!==null){const confirm=element('button','确认上一步');confirm.disabled=busy;confirm.addEventListener('click',()=>void confirmPending());boardRoot.append(confirm);}
 if(!observation)return;
 const state=observation.allowedView;
 if(rulesId==='gomoku.v1'){
  const size=state.boardSize, canvas=element('canvas');canvas.width=600;canvas.height=600;canvas.className='board';
  canvas.setAttribute('aria-label','五子棋棋盘；也可使用下方行列输入落子');
  const ctx=canvas.getContext('2d'),style=getComputedStyle(document.documentElement),step=560/(size-1);
  ctx.fillStyle=style.getPropertyValue('--maaso-muted');ctx.fillRect(0,0,600,600);
  ctx.strokeStyle=style.getPropertyValue('--maaso-divider');ctx.lineWidth=1;
  for(let i=0;i<size;i++){let p=20+i*step;ctx.beginPath();ctx.moveTo(p,20);ctx.lineTo(p,580);ctx.moveTo(20,p);ctx.lineTo(580,p);ctx.stroke();}
  state.board.forEach((stone,i)=>{if(!stone)return;ctx.fillStyle=style.getPropertyValue(stone===1?'--maaso-text-primary':'--maaso-action');ctx.beginPath();ctx.arc(20+(i%size)*step,20+Math.floor(i/size)*step,Math.min(step*.38,20),0,Math.PI*2);ctx.fill();});
  canvas.addEventListener('pointerdown',event=>{const rect=canvas.getBoundingClientRect(),x=Math.round(((event.clientX-rect.left)*600/rect.width-20)/step),y=Math.round(((event.clientY-rect.top)*600/rect.height-20)/step);void submit({x,y});});
  boardRoot.append(canvas);
  const controls=element('div',undefined,'coordinate-controls'),row=element('input'),column=element('input');
  for(const input of [row,column]){input.type='number';input.min='1';input.max=String(size);input.value='1';}
  const rowLabel=element('label','行'),columnLabel=element('label','列');rowLabel.append(row);columnLabel.append(column);
  const place=element('button','落子');place.disabled=busy||pendingRequest!==null||!observation.legalActions.length;
  place.addEventListener('click',()=>void submit({x:Number(column.value)-1,y:Number(row.value)-1}));
  controls.append(rowLabel,columnLabel,place);boardRoot.append(controls);
 } else if(rulesId==='cooperative-switches.v1') {
  const grid=element('div',undefined,'switches');
  state.switches.forEach((on,index)=>{const card=element('div',undefined,'switch-card');
   const owned=state.ownedSwitches.includes(index),target=(state.goalMask&(1<<index))!==0;
   card.append(element('p',(owned?'你的':'队友的')+'开关 '+(index+1)));
   const button=element('button',on?'已打开':'已关闭');button.setAttribute('aria-pressed',String(on));button.disabled=busy||!legal({switch:index});
   button.addEventListener('click',()=>void submit({switch:index}));card.append(button,element('small','目标：'+(target?'打开':'关闭')));grid.append(card);});
  boardRoot.append(grid);
 } else {
  const labels=['石头','布','剪刀'],cards=element('div',undefined,'cards');
  (state.hand||[]).forEach((value,index)=>{const card=element('button',labels[value]);card.disabled=busy||!legal({card:index});card.setAttribute('aria-label','选择第'+(index+1)+'张牌：'+labels[value]);card.addEventListener('click',()=>void submit({card:index}));cards.append(card);});
  boardRoot.append(cards);
  if(state.reveal)boardRoot.append(element('p','玩家 1：'+labels[state.reveal.player1]+' · 玩家 2：'+labels[state.reveal.player2]));
  else boardRoot.append(element('p','只显示你的手牌。双方选定前，不展示对方选择。','maaso-muted'));
 }
}
function game(){
 const main=element('main'),header=element('header'),name=element('h1',title),help=element('button','玩法说明','maaso-secondary');
 help.addEventListener('click',()=>void Maaso.navigate('rules',{}));header.append(name,help);
 boardRoot=element('section');main.append(header,boardRoot);
 queueMicrotask(renderBoard);return main;
}
function rules(){
 const main=element('main');boardRoot=null;
 main.append(element('h1','玩法说明'),element('p',summary),element('p','用户与 Agent 的操作都由宿主规则校验。只有收到确认回执后才会更新局面。'));
 const back=element('button','返回游戏');back.addEventListener('click',()=>void Maaso.back());main.append(back);return main;
}
Maaso.onPlayState(view=>{observation=view;renderBoard();});
void Maaso.register({routes:{game,rules},actions:{},observe:()=>({phase:observation?.phase??'unavailable',status:status()})});
})();
''';

  static const _css = '''
main{max-width:680px;margin:auto;padding:20px 16px 32px}header{display:flex;align-items:center;justify-content:space-between;gap:12px}h1{font-size:24px;line-height:1.35;margin:8px 0}header button{flex:none}.status{min-height:28px;font-weight:500}.board{width:100%;aspect-ratio:1;border-radius:16px;display:block;touch-action:manipulation}.coordinate-controls{display:flex;align-items:end;gap:12px;margin-top:16px}.coordinate-controls label{flex:1;min-width:0}.coordinate-controls input{width:100%;margin-top:4px}.switches{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}.switch-card{padding:16px;background:var(--maaso-muted);border-radius:16px}.switch-card p{margin:0 0 12px}.switch-card button{width:100%;margin-bottom:8px}.switch-card small{display:block}.cards{display:flex;gap:12px;flex-wrap:wrap}.cards button{flex:1;min-width:88px;min-height:112px;background:var(--maaso-capsule-fill);color:var(--maaso-text-primary);box-shadow:var(--maaso-frost-shadow)}@media(max-width:360px){header{align-items:start;flex-wrap:wrap}.coordinate-controls{flex-wrap:wrap}.coordinate-controls button{flex:1}.switches{gap:8px}}
''';

  // Rendering consumes only human-scoped frames. Commands always refresh the
  // reliable observation and carry the host's bounded capability token.
  static const _realtimeSource = r'''
(() => {
'use strict';
let view=Maaso.playObserve(),frame=Maaso.playFrame(),busy=false,pending=null,error='';
let canvas=null,statusNode=null,scoreNode=null,errorNode=null,confirmButton=null,buttons=[],paintQueued=false;
const el=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};
const text=(node,value)=>{if(node&&node.textContent!==value)node.textContent=value;};
const state=()=>frame?.allowedView??view?.allowedView;
const phase=()=>frame?.phase??view?.phase??'unavailable';
function status(){const s=state();if(busy)return '正在确认操作';if(pending)return '上一步还未确认，请查询回执';if(phase()==='paused')return '已暂停，请在游戏控制栏继续';if(phase()==='ready')return '准备好了，点击开始';if(phase()==='ended')return s?.teamWon?'合作成功！每人都接到了三颗星星':'这一局结束了，可以在游戏控制栏开始新局';return phase()==='playing'?'接住标有自己编号的星星，避开叉号障碍':'游戏正在准备';}
function update(){
 const s=state();text(statusNode,status());text(errorNode,error);if(confirmButton){confirmButton.hidden=pending===null;confirmButton.disabled=busy;}
 if(s){const players=s.players??[];text(scoreNode,'你 '+(players.find(p=>p.seatId===(frame?.seatId??view?.seatId))?.score??0)+'/3 · 伙伴 '+(players.find(p=>p.seatId!==(frame?.seatId??view?.seatId))?.score??0)+'/3 · 机会 '+s.teamLives+' · 剩余 '+Math.ceil(s.remainingTicks/30)+' 秒');}
 for(const b of buttons){b.disabled=busy||pending!==null||(b.dataset.policy==='start'?phase()!=='ready':phase()!=='playing');}
 schedulePaint();
}
async function submit(policy){
 if(busy||pending!==null)return;view=Maaso.playObserve();
 const action=view?.legalActions.find(a=>policy==='start'?a.actionId==='game.start':a.actionId==='game.input'&&a.args.policy===policy);
 if(!action){error='局面已变化，请稍后再试';update();return;}
 busy=true;error='';update();
 const requestId='r_'+Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
 const command={requestId,observationId:view.observationId,actionId:action.actionId,args:action.args,expectedDecisionRevision:view.decisionRevision,expectedTurnId:view.turnId,actionToken:action.actionToken};
 try{const receipt=await Maaso.playSubmit(command);if(receipt.status==='pending'){pending=requestId;}else if(receipt.status!=='applied'&&receipt.status!=='duplicate'){error='这一步未执行，请按当前状态重试';}}
 catch(_){pending=requestId;error='暂时无法确认，请先查询这一步的回执';}
 finally{busy=false;view=Maaso.playObserve();update();}
}
async function confirm(){if(busy||pending===null)return;busy=true;update();try{const r=await Maaso.playReceipt(pending);if(r&&r.status!=='pending'){pending=null;error=r.status==='applied'||r.status==='duplicate'?'':'这一步未执行';}else{error='仍在确认，请稍后再查询';}}catch(_){error='暂时无法查询，请稍后再试';}finally{busy=false;view=Maaso.playObserve();update();}}
function schedulePaint(){if(paintQueued||!canvas?.isConnected||document.hidden)return;paintQueued=true;requestAnimationFrame(()=>{paintQueued=false;if(canvas?.isConnected&&!document.hidden)paint();});}
function paint(){
 const s=state();if(!s||!canvas)return;const c=canvas.getContext('2d'),style=getComputedStyle(document.documentElement),color=name=>style.getPropertyValue('--maaso-'+name).trim();
 c.fillStyle=color('muted');c.fillRect(0,0,1000,1000);
 for(const o of s.objects){c.fillStyle=color(o.kind==='hazard'?'danger':o.ownerSeatId==='player1'?'action':'success');c.beginPath();
  if(o.kind==='star'){for(let i=0;i<10;i++){const angle=-Math.PI/2+i*Math.PI/5,r=i%2?18:38,x=o.x+Math.cos(angle)*r,y=o.y+Math.sin(angle)*r;if(i===0)c.moveTo(x,y);else c.lineTo(x,y);}c.closePath();}else c.arc(o.x,o.y,32,0,Math.PI*2);c.fill();
  c.fillStyle=color('on-action');c.font='bold 28px sans-serif';c.textAlign='center';c.textBaseline='middle';c.fillText(o.kind==='hazard'?'×':o.ownerSeatId==='player1'?'1':'2',o.x,o.y+2);
 }
 for(const p of s.players){c.fillStyle=color(p.seatId==='player1'?'action':'success');c.beginPath();c.roundRect(p.x-42,p.y-30,84,60,20);c.fill();c.fillStyle=color('on-action');c.font='bold 32px sans-serif';c.textAlign='center';c.textBaseline='middle';c.fillText(p.seatId==='player1'?'1':'2',p.x,p.y);}
}
function game(){
 const main=el('main',undefined,'dodge-game'),info=el('header',undefined,'dodge-info');info.append(el('h1','一起接星星'));
 statusNode=el('p',status(),'status');statusNode.setAttribute('role','status');scoreNode=el('p','','score');info.append(statusNode,scoreNode);main.append(info);
 const arena=el('div',undefined,'dodge-arena');canvas=el('canvas');canvas.width=1000;canvas.height=1000;canvas.className='arena';canvas.setAttribute('role','img');canvas.setAttribute('aria-label','双人接星星场地，玩家1为蓝色并标1，玩家2为绿色并标2；叉号是障碍。可用下方按钮操作。');arena.append(canvas);main.append(arena);
 const footer=el('footer',undefined,'dodge-footer');
 const controls=el('div',undefined,'dodge-controls');buttons=[];
 for(const [policy,label] of [['start','开始'],['left','向左一步'],['idle','停下'],['right','向右一步'],['collect','收集 5 秒'],['dodge','避让 5 秒']]){const b=el('button',label,policy==='start'?'':'maaso-secondary');b.dataset.policy=policy;b.addEventListener('click',()=>void submit(policy));buttons.push(b);controls.append(b);}footer.append(controls);
 errorNode=el('p','','maaso-error');errorNode.setAttribute('role','alert');confirmButton=el('button','查询上一步回执','maaso-secondary');confirmButton.hidden=true;confirmButton.addEventListener('click',()=>void confirm());footer.append(errorNode,confirmButton);
 const help=el('details'),summary=el('summary','玩法说明');help.append(summary,el('p','各接三颗自己的星星，一起避开障碍。每人接住标有自己编号的三颗星星即可合作成功。碰到叉号会减少共享机会。左右按钮移动一小步；收集和避让会执行最多五秒的本地策略，之后自动停下。可以在游戏控制栏邀请 Agent 操作另一个角色、暂停或接管。'));footer.append(help);main.append(footer);
 queueMicrotask(update);return main;
}
Maaso.onPlayState(next=>{view=next;update();});
Maaso.onPlayFrame(next=>{frame=next;update();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)update();});
void Maaso.register({routes:{game},actions:{},observe:()=>({phase:phase(),simTick:frame?.simTick??0,teamLives:state()?.teamLives??6,players:state()?.players??[]})});
})();
''';

  static const _realtimeCss = '''
main.dodge-game{max-width:680px;height:100vh;height:100dvh;margin:auto;padding:12px 16px calc(12px + env(safe-area-inset-bottom));box-sizing:border-box;display:grid;grid-template-rows:auto minmax(96px,1fr) auto;gap:8px;overflow-y:auto;overscroll-behavior:contain;scroll-padding:12px}.dodge-info{display:grid;gap:4px;min-width:0}.dodge-info h1{font-size:24px;line-height:1.35;margin:0}.dodge-info p{margin:0;overflow-wrap:anywhere}.status{font-weight:500;min-height:24px}.score{font-variant-numeric:tabular-nums}.dodge-arena{position:relative;min-width:0;min-height:0}.arena{position:absolute;inset:0;display:block;width:100%;height:100%;object-fit:contain;border-radius:var(--maaso-radius-compact);background:var(--maaso-muted)}.dodge-footer{display:grid;gap:8px;min-width:0}.dodge-footer p{margin:0;overflow-wrap:anywhere}.dodge-footer .maaso-error:empty{display:none}.dodge-controls{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}.dodge-controls button{min-width:48px;min-height:48px;padding:12px 8px;white-space:normal;line-height:1.4}.dodge-controls button[data-policy="start"]{grid-column:1/-1}.dodge-footer summary{min-height:48px;display:flex;align-items:center;cursor:pointer;color:var(--maaso-accent)}button:disabled{cursor:default;opacity:.5}button:active:not(:disabled){opacity:.75}@media(orientation:landscape) and (max-height:500px){main.dodge-game{grid-template-columns:minmax(0,1fr) minmax(240px,1fr);grid-template-rows:auto minmax(96px,1fr)}.dodge-info{grid-column:1/-1}.dodge-footer{align-self:start}}
''';
}
