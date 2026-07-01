import type { Metadata } from "next";
import { MarketingPageShell } from "../../_components/MarketingPageShell";
import { SITE_NAME, SITE_URL, hreflangAlternatesZh } from "@/lib/seo";

const DESC = "DayPage 发布了什么 —— 小版本、人话备注。iOS + macOS + Web。";

export const metadata: Metadata = {
  title: "更新日志",
  description: DESC,
  alternates: hreflangAlternatesZh("/changelog"),
  openGraph: {
    title: `更新日志 · ${SITE_NAME}`,
    description: DESC,
    url: `${SITE_URL}/zh/changelog`,
    type: "website",
    locale: "zh_CN",
    alternateLocale: ["en_US"],
    images: [{ url: "/opengraph-image.png", width: 1200, height: 630, alt: `更新日志 · ${SITE_NAME}` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `更新日志 · ${SITE_NAME}`,
    description: DESC,
    images: ["/opengraph-image.png"],
  },
};

const RELEASES = [
  {
    version: "0.5",
    date: "2026-06-29",
    title: "美术馆美学 + Maestro 流程",
    notes: [
      "Today 重设计:暖米色、美术馆般安静的 hero。",
      "Maestro 流程对齐当前 UI;双语标签。",
      "缺 API key 时静默编译,不打扰。",
    ],
  },
  {
    version: "0.4",
    date: "2026-06-15",
    title: "记忆对话 + 图谱检索",
    notes: [
      "用自然语言询问过去的日子,回答带 memo 与日期引用。",
      "图谱检索层(D2)为对话提供结构化上下文。",
    ],
  },
  {
    version: "0.3",
    date: "2026-05-30",
    title: "周回顾 + 离线队列",
    notes: ["周一早上自动编译本周回顾。", "离线捕捉队列,带安静的状态横幅。"],
  },
  {
    version: "0.2",
    date: "2026-05-10",
    title: "语音 + EXIF + 时光胶囊",
    notes: [
      "Whisper 转写语音 memo。",
      "EXIF 感知的照片 memo(光圈、快门、ISO)。",
      "时光胶囊浮现:同一日的往年记忆。",
    ],
  },
  {
    version: "0.1",
    date: "2026-04-20",
    title: "私测发布",
    notes: ["本地优先 Markdown 仓库。", "Today / Archive / Graph 三块。", "夜间编译管线。"],
  },
];

export default function Page() {
  return (
    <MarketingPageShell
      lang="zh"
      eyebrow="更新日志"
      title="小版本,人话备注。"
      lede="DayPage 接近每周发一次。备注由写代码的人自己写。"
    >
      {RELEASES.map((r) => (
        <section key={r.version} className="mt-16">
          <div className="flex items-baseline gap-4">
            <h2 className="!mt-0 !text-[22px]">v{r.version}</h2>
            <time dateTime={r.date} className="text-[13px] text-[color:var(--fg-subtle-aa)]">
              {r.date}
            </time>
          </div>
          <p className="!mt-2 !text-[18px] font-serif italic text-[color:var(--fg-primary)]">
            {r.title}
          </p>
          <ul>
            {r.notes.map((n) => (
              <li key={n}>{n}</li>
            ))}
          </ul>
        </section>
      ))}
    </MarketingPageShell>
  );
}
