// Executed only during an explicit capture, in the isolated content world.
const maxFile = 2 * 1024 * 1024, maxTotal = 20 * 1024 * 1024;
const unique = [...new Set(urls)].filter(u => !u.startsWith('data:'));
const results = [], controllers = new Set();
let index = 0, consumed = 0, expired = false;
const abort = () => { expired = true; for (const c of controllers) c.abort(); };
globalThis.__pageglassAbortAssets = abort;
const deadline = setTimeout(() => { expired = true; for (const c of controllers) c.abort(); }, 12000);
const encode = bytes => {
  let raw = '';
  for (let i = 0; i < bytes.length; i += 32768) raw += String.fromCharCode(...bytes.subarray(i, i + 32768));
  return btoa(raw);
};
async function rasterSVG(bytes, signal) {
  // SVG loaded as an image cannot execute its scripts. Export pixels, never executable SVG source.
  const objectURL = URL.createObjectURL(new Blob([bytes], {type:'image/svg+xml'}));
  const image = new Image();
  try {
    await new Promise((resolve,reject) => {
      image.onload = resolve; image.onerror = () => reject(new Error('svg-decode'));
      signal.addEventListener('abort', () => { image.src = ''; reject(new Error('timeout')); }, {once:true});
      if (signal.aborted) { reject(new Error('timeout')); return; }
      image.src = objectURL;
    });
    const w = image.naturalWidth, h = image.naturalHeight;
    if (!w || !h || w*h > 4_000_000 || w > 4096 || h > 4096) throw new Error('svg-size-limit');
    const canvas = document.createElement('canvas'); canvas.width = w; canvas.height = h;
    canvas.getContext('2d').drawImage(image,0,0);
    const base64 = canvas.toDataURL('image/png').split(',')[1];
    if (base64.length*0.75 > maxFile) throw new Error('file-size-limit');
    return base64;
  } finally { URL.revokeObjectURL(objectURL); }
}
async function worker() {
  while (index < unique.length) {
    const position = index++, url = unique[position];
    if (position >= 64 || expired || consumed >= maxTotal) { results.push({url,status:'budget-limit'}); continue; }
    if (!/^(https?:|blob:)/i.test(url)) { results.push({url,status:'unsupported-scheme'}); continue; }
    const controller = new AbortController(); controllers.add(controller);
    const timeout = setTimeout(() => controller.abort(),6000);
    try {
      const response = await fetch(url,{mode:'cors',credentials:'same-origin',signal:controller.signal,cache:'force-cache'});
      if (!response.ok) throw new Error('http-'+response.status);
      const mime = (response.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
      if (!/^(image\/(png|jpeg|gif|webp|avif|bmp|x-icon|vnd.microsoft.icon|svg\+xml)|font\/(woff2?|ttf|otf)|application\/(font-woff|font-sfnt|vnd.ms-opentype|x-font-ttf|octet-stream))$/.test(mime)) throw new Error('unsupported-type');
      if (Number(response.headers.get('content-length')) > maxFile) throw new Error('file-size-limit');
      const reader = response.body.getReader(), chunks = []; let size = 0;
      while (true) {
        const {value,done} = await reader.read(); if (done) break;
        size += value.length; consumed += value.length;
        if (size > maxFile || consumed > maxTotal) { await reader.cancel(); throw new Error('size-limit'); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
      const svg = mime === 'image/svg+xml';
      results.push({url,status:'bundled',mime:svg?'image/png':mime,base64:svg?await rasterSVG(bytes,controller.signal):encode(bytes),conversion:svg?'svg-to-png':null});
    } catch (error) {
      // Do not serialize response bodies, headers, credentials or browser error URLs.
      const known = /^(http-\d+|unsupported-type|file-size-limit|size-limit|svg-decode|svg-size-limit|timeout)$/;
      results.push({url,status:controller.signal.aborted?'timeout':known.test(error.message)?error.message:'unavailable-or-cors'});
    } finally { clearTimeout(timeout); controllers.delete(controller); }
  }
}
try { await Promise.all(Array.from({length:4},worker)); return results; }
finally { clearTimeout(deadline); for (const c of controllers) c.abort(); if (globalThis.__pageglassAbortAssets === abort) delete globalThis.__pageglassAbortAssets; }
