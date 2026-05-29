// US-052: cold-start guidance — shown on /home when no knowledge network has
// formed yet (no domains, no backlinks). Replaces the bare zeros with explicit
// guidance + concrete next steps (add a source / set up clipping).
import Link from "next/link";
import { Bookmark, Plus, Network } from "lucide-react";
import { Btn, Card, Icon } from "@/components/ui";

interface ColdStartGuideProps {
  /** How many more sources to suggest before the graph weaves itself. */
  sourcesToWeave: number;
}

export function ColdStartGuide({ sourcesToWeave }: ColdStartGuideProps) {
  return (
    <Card className="cold-start">
      <div
        style={{
          display: "flex",
          gap: 16,
          alignItems: "flex-start",
          padding: "20px 22px",
          flexWrap: "wrap",
        }}
      >
        <span
          style={{
            color: "var(--accent)",
            background: "var(--accent-soft)",
            width: 44,
            height: 44,
            borderRadius: 12,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            flexShrink: 0,
          }}
        >
          <Icon as={Network} size={22} />
        </span>
        <div style={{ flex: 1, minWidth: 240 }}>
          <p style={{ fontWeight: 600, margin: "0 0 6px", fontSize: "1.05rem" }}>
            你的知识网络还是空的
          </p>
          <p
            style={{
              color: "var(--fg-subtle)",
              margin: "0 0 16px",
              fontSize: "0.95rem",
              lineHeight: 1.5,
            }}
          >
            添加 {sourcesToWeave} 条后我会自动编织出你的第一个知识网络。
            先丢进来一些想法、链接或剪藏，剩下的交给我。
          </p>
          <div className="flex gap-12" style={{ flexWrap: "wrap" }}>
            <Link href="/add">
              <Btn kind="primary" icon={<Icon as={Plus} size={14} />}>
                添加来源
              </Btn>
            </Link>
            <Link href="/settings">
              <Btn kind="soft" icon={<Icon as={Bookmark} size={14} />}>
                设置剪藏
              </Btn>
            </Link>
          </div>
        </div>
      </div>
    </Card>
  );
}
