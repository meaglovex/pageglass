// Runs only on the app-owned diagnostic document, in an isolated content world.
// No network requests, user-page inspection or persistent storage.
function webGL(kind) {
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 4;
  let gl, program, buffer; const shaders = [];
  try {
    gl = canvas.getContext(kind, { antialias:false, failIfMajorPerformanceCaveat:true });
    if (!gl) return { status:'unavailable', detail:'未获得图形上下文' };
    const info = gl.getExtension('WEBGL_debug_renderer_info');
    const renderer = String(gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER));
    const vendor = String(gl.getParameter(info ? info.UNMASKED_VENDOR_WEBGL : gl.VENDOR));
    function shader(type, source) {
      const value = gl.createShader(type); if (!value) throw new Error('无法创建着色器');
      shaders.push(value); gl.shaderSource(value, source); gl.compileShader(value);
      if (!gl.getShaderParameter(value,gl.COMPILE_STATUS)) throw new Error('着色器编译失败');
      return value;
    }
    const modern = kind === 'webgl2';
    const vertex = modern ? '#version 300 es\nin vec2 p; void main(){gl_Position=vec4(p,0.0,1.0);}' : 'attribute vec2 p; void main(){gl_Position=vec4(p,0.0,1.0);}';
    const fragment = modern ? '#version 300 es\nprecision mediump float; out vec4 c; void main(){c=vec4(0.125,0.5,0.875,1.0);}' : 'precision mediump float; void main(){gl_FragColor=vec4(0.125,0.5,0.875,1.0);}';
    program = gl.createProgram(); if (!program) throw new Error('无法创建绘制程序');
    gl.attachShader(program,shader(gl.VERTEX_SHADER,vertex)); gl.attachShader(program,shader(gl.FRAGMENT_SHADER,fragment)); gl.linkProgram(program);
    if (!gl.getProgramParameter(program,gl.LINK_STATUS)) throw new Error('绘制程序链接失败');
    gl.useProgram(program); buffer = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
    gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),gl.STATIC_DRAW);
    const location = gl.getAttribLocation(program,'p'); gl.enableVertexAttribArray(location); gl.vertexAttribPointer(location,2,gl.FLOAT,false,0,0);
    gl.viewport(0,0,4,4); gl.drawArrays(gl.TRIANGLES,0,3);
    const pixels = new Uint8Array(4); gl.readPixels(2,2,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
    const expected = [32,128,223,255];
    const valid = gl.getError() === gl.NO_ERROR && expected.every((value,i) => Math.abs(value-pixels[i]) <= 2);
    return {status:valid?'passed':'failed',renderer,vendor,pixels:Array.from(pixels),detail:valid?'着色器绘制与像素读回通过':'像素读回与预期不符'};
  } catch (_) { return {status:'failed',detail:'图形检测未能完成'}; }
  finally {
    if (gl) {
      if (buffer) gl.deleteBuffer(buffer); if (program) gl.deleteProgram(program);
      shaders.forEach(value => gl.deleteShader(value));
      gl.getExtension('WEBGL_lose_context')?.loseContext();
    }
    canvas.remove();
  }
}
async function webGPU() {
  if (!navigator.gpu) return {status:'unavailable',detail:'当前检测环境未提供 WebGPU'};
  let device, output, readback;
  try {
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) return {status:'unavailable',detail:'未获得 WebGPU 适配器'};
    device = await adapter.requestDevice();
    output = device.createBuffer({size:4,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_SRC});
    readback = device.createBuffer({size:4,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ});
    const module = device.createShaderModule({code:'@group(0) @binding(0) var<storage, read_write> value: array<u32>; @compute @workgroup_size(1) fn main(){value[0]=42u;}'});
    const pipeline = await device.createComputePipelineAsync({layout:'auto',compute:{module,entryPoint:'main'}});
    const group = device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:output}}]});
    const encoder = device.createCommandEncoder(), pass = encoder.beginComputePass();
    pass.setPipeline(pipeline); pass.setBindGroup(0,group); pass.dispatchWorkgroups(1); pass.end();
    encoder.copyBufferToBuffer(output,0,readback,0,4); device.queue.submit([encoder.finish()]);
    await readback.mapAsync(GPUMapMode.READ);
    const value = new Uint32Array(readback.getMappedRange())[0]; readback.unmap();
    return {status:value===42?'passed':'failed',value,detail:value===42?'计算与结果读回通过':'计算结果与预期不符'};
  } catch (_) { return {status:'failed',detail:'WebGPU 计算未能完成'}; }
  finally { readback?.destroy(); output?.destroy(); device?.destroy(); }
}
return {webgl:webGL('webgl'),webgl2:webGL('webgl2'),webgpu:await webGPU(),secureContext:isSecureContext};
