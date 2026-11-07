import 'offline_models.dart';

/// Self-contained starter works. No assets, fonts, servers or downloads needed.
List<OfflineWork> offlineSampleWorks() {
  final date = DateTime.utc(2026, 11, 7);
  return [
    OfflineWork(
      id: 'sample-snake',
      title: '贪吃蛇 · Snake',
      kind: OfflineWorkKind.game,
      html: _snake,
      createdAt: date,
      updatedAt: date,
    ),
    OfflineWork(
      id: 'sample-shooter',
      title: '星际守卫 · Space Guard',
      kind: OfflineWorkKind.game,
      html: _shooter,
      createdAt: date,
      updatedAt: date,
    ),
    OfflineWork(
      id: 'sample-todo',
      title: '本地待办 · Local Tasks',
      kind: OfflineWorkKind.applet,
      html: _todo,
      createdAt: date,
      updatedAt: date,
    ),
  ];
}

const _snake =
    r'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Snake</title><style>
*{box-sizing:border-box}body{margin:0;padding:18px;font:16px system-ui;background:#101216;color:#f6f8fc;text-align:center}main{max-width:440px;margin:auto}h1{margin:0 0 8px;font-size:24px}p{color:#bcc3ce}canvas{display:block;width:100%;aspect-ratio:1;background:#18202b;border-radius:20px;touch-action:none}button{border:0;border-radius:24px;min-width:56px;min-height:48px;padding:12px 20px;background:#3b6de4;color:white;font:inherit;font-weight:600;cursor:pointer}.bar{display:flex;justify-content:space-between;align-items:center;margin:14px 0;gap:10px}.pad{display:grid;grid-template-columns:repeat(3,64px);gap:8px;justify-content:center;margin-top:16px}.pad button{background:#282d35}.hint{font-size:13px;line-height:1.5}#status{min-height:24px}
</style></head><body><main><h1>贪吃蛇</h1><p>吃到食物，避开自己。无需联网。</p><div class="bar"><strong id="score">分数 0</strong><button id="start">开始</button><button id="restart">重开</button></div><canvas id="board" width="400" height="400" aria-label="贪吃蛇棋盘"></canvas><p id="status" role="status">点击开始，用方向按钮或滑动转向</p><div class="pad"><span></span><button data-dir="0,-1" aria-label="向上">↑</button><span></span><button data-dir="-1,0" aria-label="向左">←</button><button data-dir="0,1" aria-label="向下">↓</button><button data-dir="1,0" aria-label="向右">→</button></div><p class="hint">也支持键盘方向键 · 切到后台会自动暂停</p></main><script>
(()=>{const c=document.getElementById('board'),ctx=c.getContext('2d'),scoreEl=document.getElementById('score'),status=document.getElementById('status'),start=document.getElementById('start');let snake,food,dir,next,score,state,timer;
function report(){try{window.MaasoOfflineEvents?.postMessage(JSON.stringify({type:'game_state',game:'snake',score,state}))}catch(_){}}
function spawn(){let p;do{p={x:Math.floor(Math.random()*20),y:Math.floor(Math.random()*20)}}while(snake.some(s=>s.x===p.x&&s.y===p.y));food=p}
function draw(){ctx.fillStyle='#18202b';ctx.fillRect(0,0,400,400);ctx.fillStyle='#f57070';ctx.fillRect(food.x*20+3,food.y*20+3,14,14);snake.forEach((s,i)=>{ctx.fillStyle=i?'#8ee0b0':'#3b6de4';ctx.fillRect(s.x*20+1,s.y*20+1,18,18)});scoreEl.textContent='分数 '+score;start.textContent=state==='playing'?'暂停':state==='over'?'再玩一次':'开始'}
function reset(){clearInterval(timer);snake=[{x:8,y:10},{x:7,y:10},{x:6,y:10}];dir={x:1,y:0};next=dir;score=0;state='paused';spawn();status.textContent='点击开始，用方向按钮或滑动转向';draw();report()}
function play(){if(state==='over')reset();if(state==='playing'){clearInterval(timer);state='paused';status.textContent='已暂停'}else{state='playing';status.textContent='吃到红色食物得分';timer=setInterval(tick,150)}draw();report()}
function tick(){dir=next;const h={x:snake[0].x+dir.x,y:snake[0].y+dir.y},grow=h.x===food.x&&h.y===food.y;const occupied=grow?snake:snake.slice(0,-1);if(h.x<0||h.x>=20||h.y<0||h.y>=20||occupied.some(s=>s.x===h.x&&s.y===h.y)){clearInterval(timer);state='over';status.textContent='本局结束！分数 '+score;draw();report();return}snake.unshift(h);if(grow){score++;if(snake.length===400){clearInterval(timer);state='over';status.textContent='你填满了整个棋盘！';draw();report();return}spawn();report()}else snake.pop();draw()}
function turn(x,y){if(x===-dir.x&&y===-dir.y)return;next={x,y}}
document.querySelectorAll('[data-dir]').forEach(b=>b.addEventListener('click',()=>turn(...b.dataset.dir.split(',').map(Number))));const keys={ArrowUp:[0,-1],ArrowDown:[0,1],ArrowLeft:[-1,0],ArrowRight:[1,0]};document.addEventListener('keydown',e=>{if(keys[e.key]){e.preventDefault();turn(...keys[e.key])}});let origin;c.addEventListener('pointerdown',e=>{origin={x:e.clientX,y:e.clientY};c.setPointerCapture(e.pointerId)});c.addEventListener('pointerup',e=>{if(!origin)return;const x=e.clientX-origin.x,y=e.clientY-origin.y;if(Math.max(Math.abs(x),Math.abs(y))>12){if(Math.abs(x)>Math.abs(y))turn(Math.sign(x),0);else turn(0,Math.sign(y))}origin=null});start.onclick=play;document.getElementById('restart').onclick=reset;document.addEventListener('visibilitychange',()=>{if(document.hidden&&state==='playing')play()});reset();})();
</script></body></html>''';

const _shooter =
    r'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Space Guard</title><style>
*{box-sizing:border-box}body{margin:0;padding:16px;background:#101216;color:#f6f8fc;font:16px system-ui;text-align:center}main{max-width:420px;margin:auto}h1{margin:0;font-size:24px}.bar{display:flex;align-items:center;justify-content:space-between;gap:8px;margin:12px 0}button{border:0;border-radius:24px;background:#3b6de4;color:white;min-height:48px;padding:10px 20px;font:inherit;cursor:pointer}canvas{display:block;width:100%;max-height:66vh;aspect-ratio:5/7;background:#0d1329;border-radius:20px;touch-action:none;object-fit:contain}p{color:#bcc3ce;font-size:14px;line-height:1.5}#status{min-height:22px}
</style></head><body><main><h1>星际守卫</h1><div class="bar"><strong id="score">分数 0</strong><span id="lives">生命 3</span></div><canvas id="space" width="400" height="560" aria-label="纵版战机游戏"></canvas><p id="status" role="status">点击开始，拖动战机躲避敌人</p><div class="bar"><button id="start">开始</button><button id="restart">重开</button></div><p>自动发射 · 左右拖动或方向键移动 · 完全本地运行</p></main><script>
(()=>{const canvas=document.getElementById('space'),ctx=canvas.getContext('2d'),start=document.getElementById('start'),status=document.getElementById('status');let ship,bullets,enemies,stars,score,lives,state,last=0,shot=0,spawn=0,left=false,right=false;
function report(){try{window.MaasoOfflineEvents?.postMessage(JSON.stringify({type:'game_state',game:'shooter',score,state}))}catch(_){}}
function reset(){ship=200;bullets=[];enemies=[];stars=Array.from({length:55},()=>({x:Math.random()*400,y:Math.random()*560}));score=0;lives=3;state='paused';shot=0;spawn=0;status.textContent='点击开始，拖动战机躲避敌人';update();report()}
function update(){document.getElementById('score').textContent='分数 '+score;document.getElementById('lives').textContent='生命 '+lives;start.textContent=state==='playing'?'暂停':state==='over'?'再玩一次':'开始'}
function toggle(){if(state==='over')reset();state=state==='playing'?'paused':'playing';status.textContent=state==='playing'?'拖动战机，躲避下落的敌人':'已暂停';update();report()}
function hurt(){lives--;if(lives<=0){state='over';status.textContent='本局结束！最终分数 '+score}update();report()}
function draw(dt){ctx.fillStyle='#0d1329';ctx.fillRect(0,0,400,560);ctx.fillStyle='#adb9df';for(const s of stars){if(state==='playing')s.y=(s.y+dt*.03)%560;ctx.fillRect(s.x,s.y,2,2)}ctx.fillStyle='#53c8fb';ctx.beginPath();ctx.moveTo(ship,486);ctx.lineTo(ship-18,526);ctx.lineTo(ship,517);ctx.lineTo(ship+18,526);ctx.closePath();ctx.fill();ctx.fillStyle='#ffd76c';ctx.fillRect(ship-4,521,8,14);ctx.fillStyle='#7fe8ef';for(const b of bullets)ctx.fillRect(b.x-2,b.y,4,12);for(const e of enemies){ctx.fillStyle=e.color;ctx.beginPath();ctx.moveTo(e.x,e.y+18);ctx.lineTo(e.x-17,e.y-14);ctx.lineTo(e.x+17,e.y-14);ctx.closePath();ctx.fill()}}
function frame(time){const dt=Math.min(32,time-last||16);last=time;if(state==='playing'){ship=Math.max(22,Math.min(378,ship+(right-left)*dt*.30));shot+=dt;spawn+=dt;if(shot>180){bullets.push({x:ship,y:486});shot=0}if(spawn>650){enemies.push({x:24+Math.random()*352,y:-20,color:'#fb9479'});spawn=0}bullets.forEach(b=>b.y-=dt*.45);enemies.forEach(e=>e.y+=dt*(.08+Math.min(score,300)*.0002));for(const e of enemies){for(const b of bullets){if(!e.dead&&!b.dead&&Math.abs(e.x-b.x)<18&&Math.abs(e.y-b.y)<22){e.dead=true;b.dead=true;score+=10;update();report()}}if(!e.dead&&(e.y>570||(Math.abs(e.x-ship)<28&&Math.abs(e.y-507)<26))){e.dead=true;hurt();if(state==='over')break}}bullets=bullets.filter(b=>!b.dead&&b.y>-20);enemies=enemies.filter(e=>!e.dead)}draw(dt);requestAnimationFrame(frame)}
function move(e){const r=canvas.getBoundingClientRect();ship=Math.max(22,Math.min(378,(e.clientX-r.left)*400/r.width))}canvas.addEventListener('pointerdown',e=>{canvas.setPointerCapture(e.pointerId);move(e)});canvas.addEventListener('pointermove',e=>{if(e.buttons)move(e)});document.addEventListener('keydown',e=>{if(e.key==='ArrowLeft'||e.key==='ArrowRight'){e.preventDefault();if(e.key==='ArrowLeft')left=true;else right=true}});document.addEventListener('keyup',e=>{if(e.key==='ArrowLeft')left=false;if(e.key==='ArrowRight')right=false});document.addEventListener('visibilitychange',()=>{left=false;right=false;if(document.hidden&&state==='playing')toggle()});start.onclick=toggle;document.getElementById('restart').onclick=reset;reset();requestAnimationFrame(frame);})();
</script></body></html>''';

const _todo =
    r'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Local Tasks</title><style>
*{box-sizing:border-box}body{margin:0;padding:24px 18px;background:white;color:#202124;font:16px system-ui}main{max-width:540px;margin:auto}h1{font-size:28px;margin:0 0 8px}.muted{color:#5f636b;line-height:1.6}form{display:flex;gap:8px;margin:24px 0}input[type=text]{min-width:0;flex:1;background:#f5f6f8;border:0;border-radius:22px;padding:14px 16px;font:inherit}button{border:0;border-radius:22px;background:#3b6de4;color:white;padding:12px 20px;min-height:48px;font:inherit;cursor:pointer}ul{list-style:none;padding:0}.task{display:flex;align-items:center;gap:12px;padding:14px;margin:10px 0;background:#f5f6f8;border-radius:20px}.task label{flex:1;overflow-wrap:anywhere}.task input{width:22px;height:22px;accent-color:#3b6de4}.task button{background:white;color:#5f636b;min-width:48px;padding:8px}.done{text-decoration:line-through;color:#5f636b}#empty{padding:24px 0}#error{color:#a13b4c}#summary{font-size:14px}
</style></head><body><main><h1>本地待办</h1><p class="muted">写下一件小事，完成后划掉。数据保存在本机。</p><form id="form"><input id="draft" type="text" maxlength="200" placeholder="接下来想完成什么？" aria-label="新的待办事项" required><button>添加</button></form><p id="error" role="alert"></p><p id="summary" class="muted"></p><ul id="tasks"></ul><p id="empty" class="muted">清单还是空的。添加第一件待办吧。</p></main><script>
(()=>{const key='openMaaso.sample.todo.v1';let tasks=[];const error=document.getElementById('error');try{const data=JSON.parse(localStorage.getItem(key)||'[]');if(Array.isArray(data))tasks=data.filter(x=>typeof x.text==='string'&&x.text.length<=200&&typeof x.done==='boolean').slice(0,300)}catch(_){error.textContent='本次无法读取本地缓存，仍可使用当前清单。'}function save(){try{localStorage.setItem(key,JSON.stringify(tasks));error.textContent=''}catch(_){error.textContent='本地存储不可用，当前清单可能无法保留。'}}function render(){const ul=document.getElementById('tasks');ul.replaceChildren();tasks.forEach((t,i)=>{const li=document.createElement('li');li.className='task';const label=document.createElement('label'),check=document.createElement('input'),span=document.createElement('span'),remove=document.createElement('button');check.type='checkbox';check.checked=t.done;check.setAttribute('aria-label','完成 '+t.text);check.onchange=()=>{t.done=check.checked;save();render()};span.textContent=t.text;if(t.done)span.className='done';label.append(span);remove.textContent='×';remove.setAttribute('aria-label','删除 '+t.text);remove.onclick=()=>{tasks.splice(i,1);save();render()};li.append(check,label,remove);ul.append(li)});document.getElementById('empty').hidden=tasks.length>0;document.getElementById('summary').textContent=tasks.filter(t=>t.done).length+' / '+tasks.length+' 已完成'}document.getElementById('form').onsubmit=e=>{e.preventDefault();const input=document.getElementById('draft'),text=input.value.trim();if(!text)return;if(tasks.length>=300){error.textContent='清单已达到300项，请先整理已有内容。';return}tasks.push({text,done:false});save();input.value='';render()};render()})();
</script></body></html>''';
