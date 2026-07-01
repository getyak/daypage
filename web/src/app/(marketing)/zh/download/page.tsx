import type { Metadata } from "next";
import { MarketingPageShell } from "../../_components/MarketingPageShell";
import { SITE_NAME, SITE_URL, hreflangAlternatesZh } from "@/lib/seo";

const DESC =
  "DayPage 现已上线 iOS。免费、本地优先、无需账号。macOS 内测中。";

export const metadata: Metadata = {
  title: "下载",
  description: DESC,
  alternates: hreflangAlternatesZh("/download"),
  openGraph: {
    title: `下载 · ${SITE_NAME}`,
    description: DESC,
    url: `${SITE_URL}/zh/download`,
    type: "website",
    locale: "zh_CN",
    alternateLocale: ["en_US"],
    images: [{ url: "/opengraph-image.png", width: 1200, height: 630, alt: `下载 · ${SITE_NAME}` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `下载 · ${SITE_NAME}`,
    description: DESC,
    images: ["/opengraph-image.png"],
  },
};

export default function Page() {
  return (
    <MarketingPageShell
      lang="zh"
      eyebrow="下载"
      title="免费 · 无需账号 · 你的"
      lede="DayPage 先发 iOS。macOS 内测中。Web 端用于阅读 AI 编译后的内容。"
    >
      <h2>iOS</h2>
      <p>
        需要 iOS 16 及以上。同步打磨期间通过 TestFlight 内测。发邮件到{" "}
        <a href="mailto:hello@daypage.app">hello@daypage.app</a> 申请,附一句话说你想记什么。
      </p>

      <h2>macOS</h2>
      <p>SwiftUI 桌面客户端,更宽的画布用来编辑编译后的页面。私有内测,同上邮箱。</p>

      <h2>Web</h2>
      <p>
        在任意浏览器读你的日记:<a href="/today">daypage.app/today</a>。Web 端目前只读 ——
        iOS 才是主要的捕捉入口。
      </p>

      <h2>你需要准备</h2>
      <ul>
        <li>每天大约 20 条原始 memo,语音、文字、照片、位置都行。</li>
        <li>一把 OpenAI / DeepSeek / 阿里云 DashScope 的 API key(你的数据,你的模型)。</li>
        <li>第二天早上 5 分钟读 AI 编译后的页面。</li>
      </ul>
    </MarketingPageShell>
  );
}
