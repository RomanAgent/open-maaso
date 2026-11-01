import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

SurfaceProject _project(String source) => SurfaceProject.fromJson({
  'id': 'owned-source-policy',
  'title': 'Owned local gameplay',
  'kind': 'fullscreen',
  'rendering': 'webApp',
  'experienceType': 'game',
  'html': '<main id="game"><button id="play">Play</button></main>',
  'css': '',
  'js': source,
  'manifest': {'actions': [], 'events': []},
});
List<String> _issues(String source) =>
    SurfaceProjectValidator.diagnoseForPublicGame(_project(source));

void main() {
  for (final (name, source) in <(String, String)>[
    (
      'owned constructor prototype methods',
      'function Actor(){this.x=0;}'
          'Actor.prototype.step=function(){this.x+=1;return this.x;};'
          'const actor=new Actor();actor.step();',
    ),
    (
      'owned instance passed to local gameplay helper',
      'function update(actor){actor.x+=1;}'
          'function Actor(){this.x=0;}'
          'Actor.prototype.step=function(){update(this);};'
          'const actor=new Actor();actor.step();',
    ),
    (
      'instance event callback binding retains ordinary JS semantics',
      'class Controller{constructor(){this.x=0;'
          'this.listener=this.handle.bind(this);}'
          'handle(event){this.x=event.clientX;}'
          'start(){window.addEventListener("pointerdown",this.listener);}'
          'stop(){window.removeEventListener("pointerdown",this.listener);}}'
          'const controller=new Controller();controller.start();controller.stop();',
    ),
    (
      'Array callback instance context',
      'function Controller(){this.total=0;}'
          'Controller.prototype.update=function(){'
          '[1,2].forEach(function(value){this.total+=value;},this);};'
          'const controller=new Controller();controller.update();',
    ),
    (
      'local self aliases retain instance callback identity',
      'function Controller(){this.x=0;var self=this;'
          'this.callback=function(value){self.x=value;};}'
          'const controller=new Controller();controller.callback(1);',
    ),
    (
      'nested arrow captures authored instance',
      'function update(actor){actor.x+=1;}'
          'class Actor{constructor(){this.x=0;}'
          'step(){const run=()=>{update(this);};run();}}'
          'const actor=new Actor();actor.step();',
    ),
    (
      'class field callback binds authored instance',
      'class Controller{listener=this.handle.bind(this);'
          'handle(event){return event.clientX;}}'
          'const controller=new Controller();controller.listener({clientX:1});',
    ),
    (
      'class field arrow passes authored instance',
      'function update(actor){actor.x+=1;}'
          'class Actor{x=0;step=()=>{update(this);};}'
          'const actor=new Actor();actor.step();',
    ),
    (
      'fixed aria and data attributes',
      'const button=document.getElementById("play");'
          'button.setAttribute("aria-label","Play this round");'
          'button.setAttribute("aria-pressed","false");'
          'button.setAttribute("data-state","ready");',
    ),
    ('immutable local numeric top coordinate', 'const top=10;const y=top+1;'),
    ('immutable local negative top coordinate', 'const top=-10;const y=top+1;'),
    (
      'immutable local top coordinate from owned layout constant',
      'const layout={BOARD_TOP:10};const top=layout.BOARD_TOP;const y=top+1;',
    ),
    (
      'instance canvas rectangle top coordinate',
      'class Controller{constructor(){this.canvas=document.getElementById("game");}'
          'point(){const rect=this.canvas.getBoundingClientRect();return rect.top;}}'
          'const controller=new Controller();controller.point();',
    ),
    (
      'binding to a stable locally constructed owned instance',
      'function Actor(){this.x=0;}'
          'Actor.prototype.step=function(){this.x+=1;};'
          'const actor=new Actor();const run=actor.step.bind(actor);run();',
    ),
    (
      'explicit call and apply with local owned instance',
      'function Actor(){this.x=0;}'
          'Actor.prototype.step=function(){this.x+=1;};'
          'const actor=new Actor();actor.step.call(actor);actor.step.apply(actor,[]);',
    ),
  ]) {
    test('permits $name', () {
      expect(_issues(source), isEmpty);
    });
  }

  for (final (name, source) in <(String, String)>[
    ('top-level this capture', 'const ambient=this;'),
    ('whole window capture', 'const ambient=window;'),
    ('whole globalThis capture', 'const ambient=globalThis;'),
    ('global self capture', 'const ambient=self;'),
    ('native prototype mutation', 'Array.prototype.changed=true;'),
    ('native Object prototype mutation', 'Object.prototype.changed=true;'),
    (
      'reassigned constructor',
      'function Actor(){}Actor=Array;Actor.prototype.changed=true;',
    ),
    (
      'window property replacement of global constructor',
      'function Actor(){}window.Actor=Array;Actor.prototype.changed=true;',
    ),
    (
      'globalThis property replacement of global constructor',
      'function Actor(){}globalThis.Actor=Array;Actor.prototype.changed=true;',
    ),
    (
      'self property replacement of global constructor',
      'function Actor(){}self.Actor=Array;Actor.prototype.changed=true;',
    ),
    (
      'constructor parameter shadow',
      'function Actor(){}function install(Actor){'
          'Actor.prototype.changed=true;}install(Array);',
    ),
    (
      'constructor arrow parameter shadow',
      'function Actor(){}const install=(Actor)=>Actor.prototype.changed=true;'
          'install(Array);',
    ),
    (
      'duplicate constructors cannot prove ownership',
      'function Actor(){}function Actor(){}Actor.prototype.changed=true;',
    ),
    (
      'duplicate constructor bodies cannot capture this',
      'function Actor(){return this;}function Actor(){return this;}'
          'const actor=new Actor();',
    ),
    (
      'reassigned constructor body cannot capture this',
      'function Actor(){var self=this;return self;}Actor=Array;'
          'const actor=new Actor();',
    ),
    (
      'constructor lexical variable shadow',
      'function Actor(){}function install(){const Actor=Array;'
          'Actor.prototype.changed=true;}install();',
    ),
    (
      'reassigned self instance alias',
      'function Actor(){var self=this;self=window;return self;}'
          'const actor=new Actor();',
    ),
    (
      'native constructor named function expression',
      'const local=function Array(){};Array.prototype.changed=true;',
    ),
    (
      'constructor borrowed member cannot authorize another scope',
      'function Actor(){}function factory(){const local=function Array(){};}'
          'Array.prototype.changed=true;',
    ),
    (
      'global native lifecycle channel access',
      'const channel=window.SurfaceValidationLifecycle;'
          'channel["post"+"Message"]("{}");',
    ),
    (
      'global native webkit channel access',
      'const handlers=window.webkit.messageHandlers;'
          'handlers.bridge["post"+"Message"]("{}");',
    ),
    (
      'computed this escape',
      'function Actor(){const operation="fet"+"ch";this[operation]("/endpoint");}'
          'const actor=new Actor();',
    ),
    (
      'computed window escape',
      'const operation="fet"+"ch";window[operation]("/endpoint");',
    ),
    (
      'computed owned prototype escape',
      'function Actor(){}const operation="proto"+"type";'
          'Actor[operation].changed=true;',
    ),
    (
      'computed constructor chain cannot reach Function',
      'function Actor(){}const prototype=Actor["proto"+"type"];'
          'const ctor=prototype["constr"+"uctor"];'
          'const dynamicCode=ctor["constr"+"uctor"];'
          'dynamicCode("return window")();',
    ),
    (
      'dynamic attribute name',
      'const button=document.getElementById("play");'
          'const name="aria-label";button.setAttribute(name,"Play");',
    ),
    (
      'event handler attribute',
      'document.getElementById("play").setAttribute("onclick","run()");',
    ),
    (
      'resource attribute',
      'document.getElementById("play").setAttribute("src","/endpoint");',
    ),
    (
      'inline style attribute',
      'document.getElementById("play").setAttribute("style","color:red");',
    ),
    (
      'malformed aria attribute',
      'document.getElementById("play").setAttribute("aria-","anything");',
    ),
    (
      'reassigned local top loses coordinate proof',
      'let top=10;top=20;const y=top+1;',
    ),
    ('ambient global top remains unavailable', 'const frame=top;'),
    (
      'window top cannot become local coordinate',
      'const top=window.top;const y=top;',
    ),
    (
      'global layout field cannot become local coordinate',
      'const top=window.BOARD_TOP;const y=top;',
    ),
    (
      'reassigned instance rectangle loses provenance',
      'class Controller{constructor(){this.canvas=document.getElementById("game");}'
          'point(){let rect=this.canvas.getBoundingClientRect();rect={top:10};return rect.top;}}'
          'const controller=new Controller();controller.point();',
    ),
    (
      'unknown this rectangle cannot prove owned instance',
      'const rect=this.canvas.getBoundingClientRect();const y=rect.top;',
    ),
    (
      'owned method cannot bind foreign DOM receiver',
      'function Actor(){}Actor.prototype.capture=function(){return this;};'
          'const actor=new Actor();const run=actor.capture.bind(document.body);run();',
    ),
    (
      'owned method cannot call foreign DOM receiver',
      'function Actor(){}Actor.prototype.capture=function(){return this;};'
          'const actor=new Actor();actor.capture.call(document.body);',
    ),
    (
      'owned method cannot apply foreign DOM receiver',
      'function Actor(){}Actor.prototype.capture=function(){return this;};'
          'const actor=new Actor();actor.capture.apply(document.body,[]);',
    ),
    (
      'foreign receiver alias does not prove owned instance',
      'function Actor(){}Actor.prototype.capture=function(){return this;};'
          'const actor=new Actor();const receiver=document.body;actor.capture.call(receiver);',
    ),
  ]) {
    test('delegates former ownership restriction: $name', () {
      expect(_issues(source), isEmpty, reason: name);
    });
  }
}
