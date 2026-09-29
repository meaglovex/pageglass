// Only attached by the local benchmark server to its pinned Speedometer fixture.
(() => {
  const run = new URL(document.currentScript.src).searchParams.get('run');
  const invalid = new Set();
  const loadErrors = [];
  const rememberError = value => { if (loadErrors.length < 20) loadErrors.push(value); };
  window.addEventListener('error',event=>rememberError({message:String(event.message || 'resource failed').slice(0,1000),source:event.filename || event.target?.src || event.target?.href || '',line:event.lineno || 0}),true);
  window.addEventListener('unhandledrejection',event=>rememberError({message:String(event.reason).slice(0,1000)}));
  let running = false;
  const send = data => fetch('/__bench/result/'+run,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...data,invalid:[...invalid],userAgent:navigator.userAgent,viewport:{width:innerWidth,height:innerHeight},finishedAt:new Date().toISOString()})});
  document.addEventListener('visibilitychange',()=>{if(running && document.hidden) invalid.add('page-hidden');});
  window.addEventListener('blur',()=>{if(running)setTimeout(()=>{if(!document.hasFocus())invalid.add('window-lost-focus');},0);});
  window.addEventListener('load',()=>setTimeout(()=>{
    const client=globalThis.benchmarkClient;
    if(!client) {
      send({status:'failed',error:'benchmark client unavailable',diagnostics:{readyState:document.readyState,loadErrors,
        resources:performance.getEntriesByType('resource').filter(item=>item.name.includes('/resources/')).map(item=>({path:new URL(item.name).pathname,responseStatus:item.responseStatus,duration:item.duration,bytes:item.transferSize}))}});
      return;
    }
    if(document.hidden || !document.hasFocus()) { send({status:'invalid',error:'benchmark is not foreground'}); return; }
    const finish=client.didFinishLastIteration.bind(client);
    client.didFinishLastIteration=function(metrics) {
      running=false;finish(metrics);
      send({status:invalid.size?'invalid':'completed',score:metrics.Score,metrics,suitesCount:client.suitesCount,finishedTests:client._finishedTestCount});
    };
    const handleError=client.handleError.bind(client);
    client.handleError=function(error) { running=false;handleError(error);send({status:'failed',error:String(error)}); };
    running=true; client.start();
  },1000),{once:true});
})();
