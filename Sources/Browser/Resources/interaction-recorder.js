(() => {
  'use strict';
  if (globalThis.__pageglassRecorder) return;
  const documentID=Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('');
  let enabled=false,sequence=0,pending=null,timer=null,observer=null,pointer=null;
  const controlQuery='a,button,input,select,textarea,summary,[role="button"],[role="tab"],[role="switch"],[tabindex],[onclick]';
  function selector(node) {
    const parts=[];
    for(let e=node;e instanceof Element && parts.length<6;e=e.parentElement){
      if(e.id){parts.unshift('#'+CSS.escape(e.id));break;}
      let part=e.localName;if(e.parentElement)part+=`:nth-child(${[...e.parentElement.children].indexOf(e)+1})`;parts.unshift(part);
    }
    return parts.join(' > ');
  }
  function target(event) {
    const element=event.composedPath().find(n=>n instanceof Element);
    if(!element || element.closest('[data-pageglass-overlay],input[type="password"],input[type="hidden"]'))return null;
    return element.closest(controlQuery) || (getComputedStyle(element).cursor==='pointer'?element:null);
  }
  function state(node) {
    if(!node || !node.isConnected)return {connected:false};
    const clone=node.cloneNode(true);for(const input of clone.querySelectorAll('input,textarea,[contenteditable]'))input.remove();
    const editable=node.matches('input,textarea,[contenteditable]');
    const r=node.getBoundingClientRect();
    return {connected:true,selector:selector(node),tag:node.localName,role:node.getAttribute('role'),label:(editable?node.localName:(node.getAttribute('aria-label')||clone.textContent||'')).trim().slice(0,160),expanded:node.getAttribute('aria-expanded'),selected:node.getAttribute('aria-selected'),checked:node instanceof HTMLInputElement && ['checkbox','radio'].includes(node.type)?node.checked:null,selectedIndex:node instanceof HTMLSelectElement?node.selectedIndex:null,open:node.closest('details')?.open??null,disabled:!!node.disabled,rect:{x:r.x,y:r.y,width:r.width,height:r.height}};
  }
  const locationInfo=()=>{const u=new URL(location.href);u.search='';u.hash='';u.username='';u.password='';return u.href;};
  function finish(publish) {
    if(!pending)return null;
    clearTimeout(timer);observer?.disconnect();observer=null;
    const item=pending;pending=null;
    const step={sequence:item.sequence,kind:item.kind,before:item.before,after:state(item.node),events:item.events,changes:item.changes,changesTruncated:item.truncated,observedAfterMS:Date.now()-item.started,observedAt:new Date().toISOString(),url:locationInfo()};
    if(publish)window.webkit.messageHandlers.pageglass.postMessage({type:'interaction',documentID,step});
    if(sequence>=8)stop(false);
    return step;
  }
  function begin(event) {
    if(!enabled)return;
    const node=target(event);if(!node)return;
    if(event.type==='keydown' && !['Enter',' ','Escape'].includes(event.key))return;
    if(event.type==='keydown' && node.matches('input,textarea,[contenteditable]') && event.key!=='Enter')return;
    if(pending?.node===node && Date.now()-pending.started<350){if(!pending.events.includes(event.type))pending.events.push(event.type);return;}
    finish(true);if(!enabled)return;
    const before=pointer && pointer.node===node && Date.now()-pointer.time<1500?pointer.state:state(node);pointer=null;
    const item={node,sequence:++sequence,kind:event.type==='keydown'?'activate-key':event.type,before,started:Date.now(),events:[event.type],changes:[],truncated:false};pending=item;
    observer=new MutationObserver(records=>{
      for(const mutation of records){
        const e=mutation.target instanceof Element?mutation.target:mutation.target.parentElement;
        if(!e || e.closest('[data-pageglass-overlay],input,textarea,[contenteditable]'))continue;
        if(item.changes.length>=40){item.truncated=true;break;}
        item.changes.push({selector:selector(e),kind:mutation.type,attribute:mutation.attributeName||null,added:mutation.addedNodes.length,removed:mutation.removedNodes.length});
      }
    });
    observer.observe(document.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['class','style','hidden','open','aria-expanded','aria-selected','aria-checked','disabled']});
    timer=setTimeout(()=>finish(true),350);
  }
  function remember(event){if(!enabled)return;const node=target(event);if(node)pointer={node,state:state(node),time:Date.now()};}
  function stop(flush=true){const step=flush?finish(false):null;enabled=false;clearTimeout(timer);observer?.disconnect();observer=null;pending=null;pointer=null;document.removeEventListener('pointerdown',remember,true);for(const type of ['click','change','keydown'])document.removeEventListener(type,begin,true);return step;}
  function start(){stop(false);sequence=0;enabled=true;document.addEventListener('pointerdown',remember,true);for(const type of ['click','change','keydown'])document.addEventListener(type,begin,true);return {documentID,step:{sequence:0,kind:'initial',observedAt:new Date().toISOString(),url:locationInfo()}};}
  globalThis.__pageglassRecorder={start,stop,revision:()=>({documentID,sequence,enabled})};
})();
