import type { Metadata } from "next";
import { MarketingPageShell } from "../../_components/MarketingPageShell";
import { SITE_NAME, SITE_URL, hreflangAlternatesZh } from "@/lib/seo";

const DESC = "DayPage 由一群一直在丢笔记的人做的。下面说说是谁、为什么。";

export const metadata: Metadata = {
  title: "关于",
  description: DESC,
  alternates: hreflangAlternatesZh("/about"),
  openGraph: {
    title: `关于 · ${SITE_NAME}`,
    description: DESC,
    url: `${SITE_URL}/zh/about`,
    type: "website",
    locale: "zh_CN",
    alternateLocale: ["en_US"],
    images: [{ url: "/opengraph-image.png", width: 1200, height: 630, alt: `关于 · ${SITE_NAME}` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `关于 · ${SITE_NAME}`,
    description: DESC,
    images: ["/opengraph-image.png"],
  },
};

export default function Page() {
  return (
    <MarketingPageShell
      lang="zh"
      eyebrow="关于"
      title="一群一直在丢笔记的人做的。"
      lede="DayPage 最初是一个自用工具。作者上一个日记 app 用了三个月就弃了。这个,是按必须能活下来来设计的。"
    >
      <h2>起源</h2>
      <p>
        放弃第四个日记 app 之后,作者开始思考真正的捕捉模式:嘈杂咖啡店里的语音备忘录、白板照片、入睡前两行想法。这些都不是日记条目,但都是信号。
      </p>
      <p>DayPage 把捕捉与组织分开。你倒,AI 装配,你审阅。</p>

      <h2>团队</h2>
      <p>目前是一个独立项目,设计与文案得到朋友的帮助。核心稳定后会开源部分模块。</p>

      <h2>接下来去哪</h2>
      <ul>
        <li>macOS 桌面客户端走出私测。</li>
        <li>更好的跨设备同步,依然本地优先。</li>
        <li>插件接口,连接 Twitter likes、Slack 线程等数据源。</li>
      </ul>

      <h2>找我们</h2>
      <p>
        发邮件到 <a href="mailto:hello@daypage.app">hello@daypage.app</a>,或在{" "}
        <a href="https://github.com/getyak/daypage">GitHub</a> 提 issue。
      </p>
    </MarketingPageShell>
  );
}
