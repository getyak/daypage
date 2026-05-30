"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { X, Download, Loader2 } from "lucide-react";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";
import { SHARE_TEMPLATES, type TemplateId, type ShareTemplateProps } from "./share-templates/index";

const LS_KEY = "daypage-share-template";

export type ShareCardMemo = {
  id: string;
  body: string;
  created_at: string;
  type: string;
  place_name?: string;
  weather?: string;
  photo_url?: string;
};

interface ShareCardProps {
  memo: ShareCardMemo;
  onClose: () => void;
}

type ToastState = { msg: string; key: number } | null;

function Toast({ state }: { state: ToastState }) {
  if (!state) return null;
  return (
    <div
      key={state.key}
      role="status"
      aria-live="polite"
      style={{
        position: "fixed",
        top: 20,
        left: "50%",
        transform: "translateX(-50%)",
        background: "rgba(43,40,34,0.88)",
        color: "var(--accent-soft, #F5EDE3)",
        fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
        fontSize: 12,
        letterSpacing: 0.5,
        padding: "8px 18px",
        borderRadius: 999,
        whiteSpace: "nowrap",
        zIndex: 9999,
        boxShadow: "0 4px 16px rgba(0,0,0,0.25)",
        animation: "toast-in 0.2s ease-out",
        backdropFilter: "blur(12px)",
      }}
    >
      {state.msg}
      <style>{`
        @keyframes toast-in {
          from { opacity:0; transform:translateX(-50%) translateY(-6px); }
          to   { opacity:1; transform:translateX(-50%) translateY(0); }
        }
      `}</style>
    </div>
  );
}

export function ShareCard({ memo, onClose }: ShareCardProps) {
  const [activeId, setActiveId] = useState<TemplateId>(() => {
    if (typeof window !== "undefined") {
      const stored = localStorage.getItem(LS_KEY) as TemplateId | null;
      if (stored && SHARE_TEMPLATES.some((t) => t.id === stored)) return stored;
    }
    return "minimal";
  });
  const [visible, setVisible] = useState(true);
  const [exporting, setExporting] = useState(false);
  const [toast, setToast] = useState<ToastState>(null);
  const previewRef = useRef<HTMLDivElement>(null);
  const toastTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const showToast = useCallback((msg: string) => {
    if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
    setToast({ msg, key: Date.now() });
    toastTimerRef.current = setTimeout(() => setToast(null), 2500);
  }, []);

  useEffect(() => {
    return () => {
      if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
    };
  }, []);

  const handleSelectTemplate = useCallback((id: TemplateId) => {
    setVisible(false);
    setTimeout(() => {
      setActiveId(id);
      localStorage.setItem(LS_KEY, id);
      setVisible(true);
    }, 140);
  }, []);

  const handleExport = useCallback(async () => {
    if (!previewRef.current || exporting) return;
    setExporting(true);
    try {
      await document.fonts.ready;
      const { toPng } = await import("html-to-image");
      const dataUrl = await toPng(previewRef.current, {
        width: 1080,
        height: 1350,
        pixelRatio: 1,
        style: {
          borderRadius: "0",
        },
      });
      const link = document.createElement("a");
      link.download = "daypage-share.png";
      link.href = dataUrl;
      link.click();
      showToast("已保存到 Downloads");
    } catch {
      showToast("导出失败，请重试");
    } finally {
      setExporting(false);
    }
  }, [exporting, showToast]);

  const activeEntry = SHARE_TEMPLATES.find((t) => t.id === activeId) ?? SHARE_TEMPLATES[0];
  const TemplateComponent = activeEntry.component;

  const templateProps: ShareTemplateProps = {
    body: memo.body,
    created_at: memo.created_at,
    type: memo.type,
    place_name: memo.place_name,
    weather: memo.weather,
    photo_url: memo.photo_url,
  };

  return (
    <>
      <Toast state={toast} />

      {/* Backdrop */}
      <div
        aria-hidden="true"
        onClick={onClose}
        style={{
          position: "fixed",
          inset: 0,
          background: "rgba(20,16,12,0.55)",
          backdropFilter: "blur(8px)",
          WebkitBackdropFilter: "blur(8px)",
          zIndex: 200,
        }}
      />

      {/* Modal panel */}
      <div
        role="dialog"
        aria-modal="true"
        aria-label="分享卡片"
        style={{
          position: "fixed",
          inset: 0,
          zIndex: 201,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          padding: "0 16px",
          pointerEvents: "none",
        }}
      >
        <div
          style={{
            width: "100%",
            maxWidth: 360,
            // Warm museum gradient — card dissolves into ambient (detail.jsx:768)
            background: "linear-gradient(180deg, #f3ede2 0%, #ede5d6 100%)",
            borderRadius: 24,
            overflow: "hidden",
            boxShadow: "0 24px 70px -20px rgba(60,40,15,0.4)",
            pointerEvents: "auto",
          }}
        >
          {/* Top bar */}
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              padding: "14px 14px 10px",
            }}
          >
            <GlassPillBtn aria-label="关闭" size="sm" onClick={onClose}>
              <X size={15} strokeWidth={2} aria-hidden="true" />
            </GlassPillBtn>

            {/* Centered serif title 分享卡片 (detail.jsx:777) */}
            <span
              style={{
                fontFamily: "var(--font-serif, Fraunces, Georgia, serif)",
                fontSize: 18,
                fontWeight: 600,
                color: "var(--fg-primary, #2B2822)",
              }}
            >
              分享卡片
            </span>

            <GlassPillBtn aria-label="下载图片" size="sm" onClick={handleExport} disabled={exporting}>
              {exporting ? (
                <Loader2 size={15} strokeWidth={2} aria-hidden="true" style={{ animation: "spin 0.8s linear infinite" }} />
              ) : (
                <Download size={15} strokeWidth={2} aria-hidden="true" />
              )}
            </GlassPillBtn>
          </div>

          {/* Template chips */}
          <div
            role="tablist"
            aria-label="选择模板"
            style={{
              display: "flex",
              overflowX: "auto",
              gap: 6,
              padding: "10px 14px",
              scrollbarWidth: "none",
            }}
          >
            {SHARE_TEMPLATES.map((t) => {
              const isActive = t.id === activeId;
              return (
                <button
                  key={t.id}
                  role="tab"
                  aria-selected={isActive}
                  onClick={() => handleSelectTemplate(t.id)}
                  style={{
                    flexShrink: 0,
                    borderRadius: 999,
                    padding: "10px 16px",
                    // Serif Chinese labels per design (detail.jsx:797)
                    fontFamily: "var(--font-serif, Fraunces, Georgia, serif)",
                    fontSize: 13,
                    fontWeight: isActive ? 600 : 500,
                    lineHeight: 1.4,
                    whiteSpace: "nowrap",
                    cursor: "pointer",
                    transition:
                      "background var(--motion-medium, 280ms) ease, color var(--motion-medium, 280ms) ease, transform 60ms ease, box-shadow var(--motion-medium, 280ms) ease",
                    background: isActive ? "var(--accent, #5D3000)" : "var(--surface-white, #FFFFFF)",
                    color: isActive ? "#FAF8F6" : "var(--fg-primary, #2B2822)",
                    border:
                      "0.5px solid " +
                      (isActive ? "transparent" : "var(--border-subtle, #EDE8DF)"),
                    boxShadow: isActive
                      ? "0 6px 14px -6px rgba(93,48,0,0.4)"
                      : "var(--shadow-card, 0 1px 2px rgba(0,0,0,0.04))",
                    outline: isActive ? "none" : undefined,
                  }}
                >
                  {t.label}
                </button>
              );
            })}
          </div>

          {/* Preview card */}
          <div style={{ padding: "8px 14px 16px" }}>
            <div
              style={{
                width: "100%",
                aspectRatio: "4/5",
                position: "relative",
                overflow: "hidden",
                borderRadius: 18,
              }}
            >
              {/* Spinner overlay during export */}
              {exporting && (
                <div
                  style={{
                    position: "absolute",
                    inset: 0,
                    zIndex: 10,
                    background: "rgba(255,255,255,0.6)",
                    backdropFilter: "blur(4px)",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    borderRadius: 18,
                  }}
                >
                  <Loader2
                    size={28}
                    strokeWidth={2}
                    style={{ animation: "spin 0.8s linear infinite", color: "var(--accent, #C0784A)" }}
                  />
                </div>
              )}

              {/* Template render */}
              <div
                ref={previewRef}
                style={{
                  width: "100%",
                  height: "100%",
                  opacity: visible ? 1 : 0,
                  transition: "opacity 280ms ease-out",
                }}
              >
                <TemplateComponent {...templateProps} />
              </div>
            </div>
          </div>
        </div>
      </div>

      <style>{`
        @keyframes spin { to { transform: rotate(360deg); } }
      `}</style>
    </>
  );
}
