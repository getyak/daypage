"use client";

import { useEffect, useRef, useState } from "react";

const FRAG = /* glsl */ `
precision highp float;
uniform vec2  uResolution;
uniform float uTime;
uniform vec3  uBase;
uniform vec3  uAccent;
uniform vec3  uHighlight;

// 2D simplex noise — Ashima Arts, MIT.
vec3 mod289(vec3 x){return x - floor(x*(1.0/289.0))*289.0;}
vec2 mod289(vec2 x){return x - floor(x*(1.0/289.0))*289.0;}
vec3 permute(vec3 x){return mod289(((x*34.0)+1.0)*x);}
float snoise(vec2 v){
  const vec4 C = vec4(0.211324865405187, 0.366025403784439,
                     -0.577350269189626, 0.024390243902439);
  vec2 i  = floor(v + dot(v, C.yy));
  vec2 x0 = v -   i + dot(i, C.xx);
  vec2 i1 = (x0.x > x0.y) ? vec2(1.0,0.0) : vec2(0.0,1.0);
  vec4 x12 = x0.xyxy + C.xxzz; x12.xy -= i1;
  i = mod289(i);
  vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0))
                       + i.x + vec3(0.0, i1.x, 1.0));
  vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
  m = m*m; m = m*m;
  vec3 x = 2.0 * fract(p * C.www) - 1.0;
  vec3 h = abs(x) - 0.5;
  vec3 ox = floor(x + 0.5);
  vec3 a0 = x - ox;
  m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
  vec3 g;
  g.x  = a0.x  * x0.x  + h.x  * x0.y;
  g.yz = a0.yz * x12.xz + h.yz * x12.yw;
  return 130.0 * dot(m, g);
}

void main(){
  vec2 p = (gl_FragCoord.xy - 0.5*uResolution.xy) / min(uResolution.x, uResolution.y);
  float t = uTime * 0.05;
  float n1 = snoise(p * 0.9 + vec2(t,        t*0.7));
  float n2 = snoise(p * 1.8 - vec2(t*0.6, -t*0.4));
  float n  = 0.55 * n1 + 0.45 * n2;
  float v  = smoothstep(-0.2, 0.9, n);
  float vig = smoothstep(1.05, 0.35, length(p));

  vec3 col = mix(uBase, uHighlight, v * 0.6);
  col = mix(col, uAccent, smoothstep(0.78, 1.0, v) * 0.08);
  col = mix(uBase, col, vig);
  gl_FragColor = vec4(col, 1.0);
}
`;

const VERT = /* glsl */ `
attribute vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
`;

const RGB_BASE = [0.980, 0.973, 0.965] as const;
const RGB_ACCENT = [0.365, 0.188, 0.000] as const;
const RGB_HIGHLIGHT = [0.788, 0.651, 0.467] as const;

export function ShaderBackground({ className }: { className?: string }) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const [fallback, setFallback] = useState(false);

  useEffect(() => {
    if (typeof window === "undefined") return;

    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const lowEnd = (navigator.hardwareConcurrency ?? 4) < 4;
    if (reduced || lowEnd) {
      setFallback(true);
      return;
    }

    const canvas = canvasRef.current;
    if (!canvas) return;

    let disposed = false;
    let rafId = 0;
    let cleanup: (() => void) | null = null;

    void import("ogl").then(({ Renderer, Program, Mesh, Triangle }) => {
      if (disposed) return;

      let renderer: InstanceType<typeof Renderer>;
      try {
        renderer = new Renderer({
          canvas,
          dpr: Math.min(window.devicePixelRatio, 1.5),
          alpha: false,
          antialias: false,
        });
      } catch {
        setFallback(true);
        return;
      }

      const gl = renderer.gl;
      gl.clearColor(RGB_BASE[0], RGB_BASE[1], RGB_BASE[2], 1);

      const geometry = new Triangle(gl);
      const program = new Program(gl, {
        vertex: VERT,
        fragment: FRAG,
        uniforms: {
          uResolution: { value: [gl.canvas.width, gl.canvas.height] },
          uTime: { value: 0 },
          uBase: { value: [...RGB_BASE] },
          uAccent: { value: [...RGB_ACCENT] },
          uHighlight: { value: [...RGB_HIGHLIGHT] },
        },
      });
      const mesh = new Mesh(gl, { geometry, program });

      const resize = () => {
        const rect = canvas.getBoundingClientRect();
        renderer.setSize(rect.width, rect.height);
        program.uniforms.uResolution.value = [gl.canvas.width, gl.canvas.height];
      };
      resize();
      window.addEventListener("resize", resize, { passive: true });

      const start = performance.now();
      const loop = (now: number) => {
        program.uniforms.uTime.value = (now - start) / 1000;
        renderer.render({ scene: mesh });
        rafId = requestAnimationFrame(loop);
      };
      rafId = requestAnimationFrame(loop);

      cleanup = () => {
        window.removeEventListener("resize", resize);
        cancelAnimationFrame(rafId);
        gl.getExtension("WEBGL_lose_context")?.loseContext();
      };
    });

    return () => {
      disposed = true;
      cancelAnimationFrame(rafId);
      cleanup?.();
    };
  }, []);

  if (fallback) {
    return (
      <div
        aria-hidden
        className={className}
        style={{
          background:
            "radial-gradient(ellipse 90% 60% at 50% 30%, rgba(93,48,0,0.06), transparent 60%), radial-gradient(ellipse 70% 50% at 70% 80%, rgba(201,166,119,0.18), transparent 60%), var(--bg-warm)",
        }}
      />
    );
  }

  return (
    <canvas
      ref={canvasRef}
      aria-hidden
      className={className}
      style={{ display: "block", width: "100%", height: "100%" }}
    />
  );
}
