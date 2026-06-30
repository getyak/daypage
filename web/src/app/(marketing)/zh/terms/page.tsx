import type { Metadata } from "next";
import { MarketingPageShell } from "../../_components/MarketingPageShell";

export const metadata: Metadata = {
  title: "服务条款",
  description: "DayPage 服务条款,短句直白。",
  alternates: {
    canonical: "/zh/terms",
    languages: { en: "/terms", "zh-CN": "/zh/terms" },
  },
  openGraph: { locale: "zh_CN" },
};

export default function Page() {
  return (
    <MarketingPageShell
      lang="zh"
      eyebrow="服务条款"
      title="短句直白。"
      lede="DayPage 按现状提供。爱护你的数据,做好备份。爱护你的模型,自带 API key。"
    >
      <h2>日记属于你</h2>
      <p>
        你在 DayPage 中捕捉的所有内容归你所有。我们对你的 memo、照片、录音、编译页面不主张任何权利。
      </p>

      <h2>API key 由你负责</h2>
      <p>自带 LLM key 意味着该服务商的使用费由你承担。我们不代理你的流量。</p>

      <h2>无担保</h2>
      <p>
        软件按现状提供,不附带任何担保。请定期备份你的 Markdown 仓库。我们还很早期,bug 会有。
      </p>

      <h2>合理使用</h2>
      <ul>
        <li>不要用 DayPage 伤害他人。</li>
        <li>不要反向工程 AI 管线去滥用第三方 API。</li>
      </ul>

      <h2>变更</h2>
      <p>条款可能会更新;重大变更会在 changelog 公告。</p>
    </MarketingPageShell>
  );
}
