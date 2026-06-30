import type { Metadata } from "next";
import { MarketingPageShell } from "../../_components/MarketingPageShell";

export const metadata: Metadata = {
  title: "隐私",
  description:
    "DayPage 在架构上就是本地优先。你的原始 memo 以 Markdown 形式存在设备上。我们不会出售或分享你的日记数据,任何时候都不会。",
  alternates: {
    canonical: "/zh/privacy",
    languages: { en: "/privacy", "zh-CN": "/zh/privacy" },
  },
  openGraph: { locale: "zh_CN" },
};

export default function Page() {
  return (
    <MarketingPageShell
      lang="zh"
      eyebrow="隐私"
      title="你的日记,始终是你的。"
      lede="本地优先不是一句口号 —— 是架构本身。下面说清:什么东西碰网络、什么时候碰、为什么碰。"
    >
      <h2>什么留在本地</h2>
      <p>
        原始 memo、附件、录音、编译后的 Markdown 日记,全都存在你设备上的一个 Markdown 仓库里。你可以把整个文件夹拷走、在 Obsidian 里打开、烧到 U 盘上。
      </p>

      <h2>什么会走网络</h2>
      <ul>
        <li>
          <strong>AI 编译</strong>:凌晨 2 点,当天的原始文本(不含音频、不含图片)发送到你配置的 LLM 服务(OpenAI / DeepSeek / 阿里云 DashScope)。你自己带 key。
        </li>
        <li>
          <strong>语音转写</strong>:只在你启用时,把单条 M4A 录音发给 Whisper。
        </li>
        <li>
          <strong>天气与反向地理编码</strong>:匿名经纬度发给 OpenWeatherMap 和 Apple,从不与你的身份关联。
        </li>
      </ul>

      <h2>我们从不</h2>
      <ul>
        <li>出售你的数据。没有广告模式。</li>
        <li>拿你的日记训练模型。</li>
        <li>跨 app 追踪你。</li>
        <li>强制账号才能捕捉。</li>
      </ul>

      <h2>崩溃遥测</h2>
      <p>可选的 Sentry 崩溃报告,只在你同意时启用。从不附带 memo 内容。</p>

      <h2>有问题</h2>
      <p>
        发邮件到 <a href="mailto:hello@daypage.app">hello@daypage.app</a>,我们会回。
      </p>
    </MarketingPageShell>
  );
}
