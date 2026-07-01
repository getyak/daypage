import type { Metadata } from "next";
import { MarketingPageShell } from "../../_components/MarketingPageShell";
import { SITE_NAME, SITE_URL, hreflangAlternatesZh } from "@/lib/seo";

const DESC = "DayPage 的常见问题 —— 价格、隐私、模型、同步、平台。";

export const metadata: Metadata = {
  title: "常见问题",
  description: DESC,
  alternates: hreflangAlternatesZh("/faq"),
  openGraph: {
    title: `常见问题 · ${SITE_NAME}`,
    description: DESC,
    url: `${SITE_URL}/zh/faq`,
    type: "website",
    locale: "zh_CN",
    alternateLocale: ["en_US"],
    images: [{ url: "/opengraph-image.png", width: 1200, height: 630, alt: `常见问题 · ${SITE_NAME}` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `常见问题 · ${SITE_NAME}`,
    description: DESC,
    images: ["/opengraph-image.png"],
  },
};

const FAQS = [
  {
    q: "DayPage 收费吗?",
    a: "免费。App 免费;你自带 LLM key,所以唯一的运行成本是 AI 调用费 —— 一般每月不到 1 美元。",
  },
  {
    q: "我的数据存在哪里?",
    a: "你设备上的 Markdown 仓库文件夹里。可以用 Obsidian 打开、拷到 U 盘上、放进任何你信任的同步服务。",
  },
  {
    q: "你们会拿我的日记训练模型吗?",
    a: "不会。我们绝不用用户数据训练模型。你的原始 memo 也不会进我们的服务器 —— 它从你设备直接发到你配置的 LLM 服务商。",
  },
  {
    q: "AI 到底做了什么?",
    a: "每晚凌晨 2 点左右,AI 读完当天 memo,产出:结构化日记页、提到的人物/地点/项目的实体页、并入正在生长的知识图谱。早上你来审阅。",
  },
  {
    q: "支持哪些模型?",
    a: "OpenAI(gpt-4 / gpt-4o)、DeepSeek(deepseek-chat / deepseek-reasoner)、阿里云 DashScope(qwen3.5-plus)。语音转写用 Whisper。都可配置。",
  },
  {
    q: "离线能用吗?",
    a: "捕捉完全离线 —— 语音、文字、照片都在本地排队。编译需要联网调 LLM。有内容排队时会显示一个安静的横幅。",
  },
  {
    q: "有 Web 版吗?",
    a: "Web 目前只读 —— 在 daypage.app/today 看 AI 编译后的页面。iOS 是主要的捕捉入口。macOS 内测中。",
  },
  {
    q: "能整体导出吗?",
    a: "你的仓库本身就是导出物 —— 一个 Markdown 文件夹。没有专有数据库锁定。拖走、拷贝、纳入版本控制都行。",
  },
];

export default function Page() {
  const faqJsonLd = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    inLanguage: "zh-CN",
    mainEntity: FAQS.map((f) => ({
      "@type": "Question",
      name: f.q,
      acceptedAnswer: { "@type": "Answer", text: f.a },
    })),
    url: `${SITE_URL}/zh/faq`,
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faqJsonLd) }}
      />
      <MarketingPageShell
        lang="zh"
        eyebrow="常见问题"
        title="最先想到的那些问题。"
        lede="简短回答。少了什么 —— 发邮件给我们,这一页我们会持续诚实更新。"
      >
        {FAQS.map((f, i) => (
          <details
            key={f.q}
            className="group mt-4 rounded-2xl border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/60 p-6 transition-colors hover:border-[color:var(--border-default)]"
            open={i === 0}
          >
            <summary className="cursor-pointer list-none text-[18px] font-medium text-[color:var(--fg-primary)] [&::-webkit-details-marker]:hidden">
              <span className="mr-3 text-[color:var(--accent)]">+</span>
              {f.q}
            </summary>
            <p className="mt-3 !text-[15px] !leading-[1.7] !text-[color:var(--fg-muted)]">
              {f.a}
            </p>
          </details>
        ))}
      </MarketingPageShell>
    </>
  );
}
