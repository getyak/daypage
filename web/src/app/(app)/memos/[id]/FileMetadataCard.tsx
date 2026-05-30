"use client";

import { useState, useRef, useEffect } from "react";
import { MoreHorizontal, AlertTriangle } from "lucide-react";
import { GlassPillBtn } from "@/components/ui/GlassPillBtn";

interface FileMetadataCardProps {
  created_at: string;
  path?: string | null;
  content_hash?: string | null;
  memo_id: string;
}

const MENU_ITEMS = [
  { label: "转移日期", value: "transfer" },
  { label: "复制纯文本", value: "copy" },
  { label: "标记重要", value: "pin" },
  { label: "导出 PDF", value: "export" },
  { label: "删除", value: "delete", danger: true },
];

type Toast = { msg: string; id: number };

function useToast() {
  const [toast, setToast] = useState<Toast | null>(null);
  const show = (msg: string) => setToast({ msg, id: Date.now() });
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 2000);
    return () => clearTimeout(t);
  }, [toast]);
  return { toast, show };
}

export function FileMetadataCard({ created_at, path, content_hash, memo_id }: FileMetadataCardProps) {
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const { toast, show: showToast } = useToast();

  const dateObj = new Date(created_at);
  const dateStr = dateObj.toISOString().slice(0, 10);
  const derivedPath = path ?? `vault/raw/${dateStr}.md`;
  const hashDisplay = content_hash
    ? `${content_hash.slice(0, 6)} · ${content_hash.slice(-5)}`
    : "—";

  useEffect(() => {
    if (!menuOpen) return;
    function handleClickOutside(e: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, [menuOpen]);

  function handleCopyHash() {
    if (!content_hash) return;
    navigator.clipboard.writeText(content_hash).then(() => showToast("已复制 hash"));
  }

  function handleMenuAction(value: string) {
    setMenuOpen(false);
    if (value === "delete") {
      setConfirmDelete(true);
    } else if (value === "copy") {
      showToast("已复制纯文本");
    }
    // Other actions: no-op stubs for now
  }

  const monoSm: React.CSSProperties = {
    fontFamily: "var(--font-mono)",
    fontSize: "11.5px",
    letterSpacing: "0.2px",
  };

  const labelStyle: React.CSSProperties = {
    ...monoSm,
    color: "var(--fg-subtle)",
    textTransform: "uppercase",
    fontWeight: 600,
    alignSelf: "start",
    paddingTop: 1,
  };

  const valueStyle: React.CSSProperties = {
    ...monoSm,
    color: "var(--fg-primary)",
    wordBreak: "break-all",
  };

  return (
    <>
      <div style={{ padding: "0 22px 24px", marginTop: 28, position: "relative" }}>
        {/* SectionLabel — mono 10/700/ls1.8 (detail.jsx:366, 411-420) */}
        <div style={{ display: "flex", alignItems: "baseline", paddingBottom: 8 }}>
          <span
            style={{
              fontFamily: "var(--font-mono)",
              fontWeight: 700,
              fontSize: 10,
              letterSpacing: "1.8px",
              color: "var(--fg-muted)",
            }}
          >
            FILE
          </span>
        </div>
        <div
          style={{
            padding: "14px 16px",
            borderRadius: 14,
            border: "0.5px solid var(--border-default)",
            background: "var(--surface-white)",
            boxShadow: "var(--shadow-card)",
          }}
        >
          {/* Three-dot menu button */}
          <div style={{ position: "relative", display: "inline-block", float: "right" }} ref={menuRef}>
            <GlassPillBtn
              aria-label="更多操作"
              size="sm"
              onClick={() => setMenuOpen((v) => !v)}
            >
              <MoreHorizontal size={14} />
            </GlassPillBtn>

            {menuOpen && (
              <div
                style={{
                  position: "absolute",
                  right: 0,
                  top: "calc(100% + 6px)",
                  minWidth: 160,
                  borderRadius: 12,
                  background: "var(--surface-white)",
                  border: "0.5px solid var(--border-default)",
                  boxShadow: "0 8px 24px rgba(0,0,0,0.12)",
                  overflow: "hidden",
                  zIndex: 100,
                }}
              >
                {MENU_ITEMS.map((item) => (
                  <button
                    key={item.value}
                    type="button"
                    onClick={() => handleMenuAction(item.value)}
                    style={{
                      display: "block",
                      width: "100%",
                      padding: "10px 14px",
                      background: "none",
                      border: "none",
                      textAlign: "left",
                      fontSize: "13px",
                      cursor: "pointer",
                      color: item.danger ? "var(--error, #ef4444)" : "var(--fg-primary)",
                      fontWeight: item.danger ? 500 : 400,
                    }}
                    onMouseEnter={(e) => {
                      (e.currentTarget as HTMLElement).style.background = "var(--surface-sunken)";
                    }}
                    onMouseLeave={(e) => {
                      (e.currentTarget as HTMLElement).style.background = "none";
                    }}
                  >
                    {item.label}
                  </button>
                ))}
              </div>
            )}
          </div>

          {/* Metadata grid */}
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "80px 1fr",
              rowGap: 11,
              columnGap: 14,
            }}
          >
            <span style={labelStyle}>CREATED</span>
            <span style={valueStyle}>{created_at}</span>

            <span style={labelStyle}>PATH</span>
            <span style={valueStyle}>{derivedPath}</span>

            <span style={labelStyle}>HASH</span>
            <button
              type="button"
              onClick={handleCopyHash}
              title="点击复制完整 hash"
              style={{
                ...valueStyle,
                fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
                letterSpacing: "0.4px",
                background: "none",
                border: "none",
                padding: 0,
                cursor: content_hash ? "pointer" : "default",
                textAlign: "left",
                color: content_hash ? "var(--fg-primary)" : "var(--fg-subtle)",
              }}
            >
              {hashDisplay}
            </button>
          </div>
        </div>
      </div>

      {/* Toast */}
      {toast && (
        <div
          style={{
            position: "fixed",
            bottom: 32,
            left: "50%",
            transform: "translateX(-50%)",
            padding: "8px 18px",
            borderRadius: 999,
            background: "rgba(30,24,18,0.88)",
            color: "#fff",
            fontSize: "13px",
            fontWeight: 500,
            backdropFilter: "blur(8px)",
            WebkitBackdropFilter: "blur(8px)",
            zIndex: 9999,
            pointerEvents: "none",
            whiteSpace: "nowrap",
          }}
        >
          {toast.msg}
        </div>
      )}

      {/* Delete confirmation dialog */}
      {confirmDelete && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            background: "rgba(0,0,0,0.45)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            zIndex: 9998,
            padding: 24,
          }}
          onClick={() => setConfirmDelete(false)}
        >
          <div
            style={{
              background: "var(--surface-white)",
              borderRadius: 18,
              padding: "28px 24px 20px",
              maxWidth: 360,
              width: "100%",
              boxShadow: "0 16px 48px rgba(0,0,0,0.2)",
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 10,
                marginBottom: 12,
              }}
            >
              <AlertTriangle size={20} style={{ color: "var(--error, #ef4444)", flexShrink: 0 }} />
              <span style={{ fontSize: "15px", fontWeight: 600, color: "var(--fg-primary)" }}>
                确认删除这条 memo？
              </span>
            </div>
            <p style={{ fontSize: "13px", color: "var(--fg-muted)", marginBottom: 20, lineHeight: 1.5 }}>
              此操作不可撤销
            </p>
            <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
              <button
                type="button"
                onClick={() => setConfirmDelete(false)}
                style={{
                  padding: "8px 18px",
                  borderRadius: 10,
                  border: "0.5px solid var(--border-default)",
                  background: "var(--surface-sunken)",
                  fontSize: "13px",
                  cursor: "pointer",
                  color: "var(--fg-primary)",
                }}
              >
                取消
              </button>
              <button
                type="button"
                onClick={() => {
                  setConfirmDelete(false);
                  // Actual delete action wired in a future story
                }}
                style={{
                  padding: "8px 18px",
                  borderRadius: 10,
                  border: "none",
                  background: "var(--error, #ef4444)",
                  fontSize: "13px",
                  cursor: "pointer",
                  color: "#fff",
                  fontWeight: 500,
                }}
              >
                删除
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
