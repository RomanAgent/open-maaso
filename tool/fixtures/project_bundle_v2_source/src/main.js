(function(){
  'use strict';
  var current='home';
  var items=[];
  function node(tag,text){var e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e;}
  function button(text,run){var b=node('button',text);b.type='button';b.addEventListener('click',run);return b;}
  function home(){current='home';var main=node('section');main.appendChild(node('h1','离线清单'));main.appendChild(node('p','在清单和详情之间切换。'));var icon=node('img');icon.src=Maaso.asset('assets/dot.png');icon.alt='清单图标';icon.width=24;icon.height=24;main.appendChild(icon);main.appendChild(button('查看详情',function(){Maaso.navigate('details',{});}));return main;}
  function details(){current='details';var main=node('section');main.appendChild(node('h1','清单详情'));main.appendChild(node('p',items.length+' 项'));items.forEach(function(text){main.appendChild(node('p',text));});main.appendChild(button('返回清单',function(){Maaso.back();}));return main;}
  Maaso.register({routes:{home:home,details:details},actions:{'app.navigate':function(args){return Maaso.navigate(args.routeId,{});},'list.addItem':function(args){items.push(args.text);return {count:items.length};}},observe:function(){return {routeId:current,items:items.slice()};}});
})();
