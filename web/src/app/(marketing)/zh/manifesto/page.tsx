import type { Metadata } from "next";
import { MarketingPageShell } from "../../_components/MarketingPageShell";

export const metadata: Metadata = {
  title: "宣言",
  description:
    "DayPage 存在的理由 —— 一个本地优先、AI 辅助的日记,献给宁愿先记下也不愿表演的人。",
  alternates: {
    canonical: "/zh/manifesto",
    languages: { en: "/manifesto", "zh-CN": "/zh/manifesto" },
  },
  openGraph: { locale: "zh_CN" },
};

export default function Page() {
  return (
    <MarketingPageShell
      lang="zh"
      eyebrow="宣言"
      title="一个真正会被用起来的日记,胜过一个完美却被弃用的日记。"
      lede="DayPage 围绕记忆真正的工作方式 —— 零碎、片段、大部分会被遗忘 —— 来设计。它白天收集原始素材,夜里让 AI 编织出来。"
    >
      <h2>日记的真正问题</h2>
      <p>
        大多数日记要求一种表演:完整的句子、平静的心情、回顾性的智慧。等你三件事齐了,这一天也就过去了。
      </p>
      <p>
        我们把碎片扔给信任的人 —— 朋友、群聊、语音备忘录。真正的信号就在那里。DayPage 认真对待这种输入方式。
      </p>

      <h2>三条原则</h2>
      <h3>1. 本地优先,始终如此。</h3>
      <p>
        你的原始 memo 以 Markdown 形式存在设备上。不要账号,只在你同意时同步。即使我们明天消失,你的日记还在,任何文本编辑器都能打开。
      </p>
      <h3>2. 捕捉神圣,编译可以有主张。</h3>
      <p>
        Today 是一个零门槛收件箱。没有格式要求、没有标题要求、没有心情打卡。凌晨 2 点,一个 LLM 读完当天,产出结构化页面:地点、人物、主题、决定、未完成的线索。
      </p>
      <h3>3. 图谱是副产品,不是目标。</h3>
      <p>
        实体与连接在编译时被发现,而不是在书写时被强制。知识图谱长出来,是因为你过了一段日子,不是因为你标注了它。
      </p>

      <h2>这是给谁用的</h2>
      <p>
        数字游民、创造者、研究者,以及一切一周变化大到塞不进 Notion 模板的人。如果你曾经试过开始写日记三次都放弃了,这是第四次,会坚持下来的那一次。
      </p>
    </MarketingPageShell>
  );
}
