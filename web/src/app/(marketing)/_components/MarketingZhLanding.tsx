"use client";

import Link from "next/link";
import { motion, useReducedMotion } from "framer-motion";
import type { SessionUser } from "@/lib/auth/session";
import { LenisProvider } from "./LenisProvider";
import { NavClient } from "./NavClient";
import { Footer } from "./Footer";
import { ShaderBackground } from "./ShaderBackground";
import { DeviceConstellation } from "./DeviceConstellation";
import { PlatformStrip } from "./PlatformStrip";

const PILLARS = [
  {
    title: "捕捉,毫无门槛",
    body: "语音、文字、照片、位置随手记入 Today。没有标题,没有心情打卡,没有格式束缚。",
  },
  {
    title: "AI,凌晨编译",
    body: "每天 2:00,AI 把当日碎片整理成结构化日记,自动抽取人物、地点、项目。",
  },
  {
    title: "知识图谱,自然生长",
    body: "实体页面在编译时被发现,而不是被强制标注。你只管生活,图谱自己长出来。",
  },
];

const BADGES = ["本地优先", "隐私默认", "自带 LLM Key", "Markdown 仓库"];

type Props = { user: SessionUser | null };

export function MarketingZhLanding({ user }: Props) {
  const reduced = useReducedMotion();

  return (
    <LenisProvider>
      <main
        id="main"
        lang="zh-CN"
        className="relative bg-[color:var(--bg-warm)]"
      >
        <NavClient user={user} lang="zh" />

        <section className="relative isolate overflow-hidden">
          <div className="absolute inset-0 -z-10">
            <ShaderBackground className="h-full w-full" />
          </div>

          <div className="mx-auto grid min-h-[100svh] max-w-[1280px] grid-cols-1 items-center gap-12 px-6 pb-24 pt-32 lg:grid-cols-[1.1fr_0.9fr] lg:gap-16 lg:px-10">
            <div className="relative">
              <motion.p
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ duration: 0.6, ease: [0.16, 1, 0.3, 1] }}
                className="mb-6 inline-flex items-center gap-2 rounded-full border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/70 px-3 py-1 text-[12px] font-medium text-[color:var(--fg-subtle-aa)] backdrop-blur"
              >
                <span className="h-1.5 w-1.5 rounded-full bg-[color:var(--accent)]" />
                内测中 · iOS
              </motion.p>

              <h1 className="font-serif text-[clamp(40px,6.4vw,72px)] leading-[1.1] tracking-[-0.02em] text-[color:var(--fg-primary)]">
                你的一天,
                <br />
                先记下,
                <br />
                <span className="italic text-[color:var(--accent)]">AI 再整理。</span>
              </h1>

              <p className="mt-7 max-w-[520px] text-[17px] leading-[1.7] text-[color:var(--fg-muted)]">
                把语音、文字、照片随手扔进 Today。凌晨 2 点,AI
                把当天碎片编译成结构化日记和持续生长的知识图谱。
              </p>

              <div className="mt-9 flex flex-col items-start gap-3 sm:flex-row sm:items-center">
                <Link
                  href="/download"
                  className="cta-magnetic inline-flex h-12 items-center justify-center rounded-full bg-[color:var(--accent)] px-7 text-[15px] font-medium text-[color:var(--bg-warm)] shadow-[0_8px_24px_-12px_rgba(93,48,0,0.6)] hover:bg-[color:var(--accent-hover)]"
                >
                  开始记录第一天 →
                </Link>
                <Link
                  href="/manifesto"
                  className="inline-flex h-12 items-center justify-center rounded-full border border-[color:var(--border-default)] bg-[color:var(--surface-white)]/80 px-6 text-[15px] font-medium text-[color:var(--fg-primary)] backdrop-blur transition-colors hover:border-[color:var(--fg-muted)]"
                >
                  阅读宣言
                </Link>
                <Link
                  href="/"
                  hrefLang="en"
                  className="text-[13px] text-[color:var(--fg-subtle-aa)] underline-offset-4 hover:text-[color:var(--fg-primary)] hover:underline"
                >
                  English ↗
                </Link>
              </div>

              <p className="mt-6 text-[13px] text-[color:var(--fg-subtle-aa)]">
                免费 · 无需账号 · 本地优先
              </p>
            </div>

            <div className="relative flex w-full justify-center lg:justify-end">
              <div className="w-full max-w-[640px]">
                <DeviceConstellation />
              </div>
            </div>
          </div>
        </section>

        <section
          aria-label="DayPage 的承诺"
          className="border-y border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/40"
        >
          <div className="mx-auto max-w-[1280px] px-6 py-12 lg:px-10">
            <ul className="flex flex-wrap gap-2.5">
              {BADGES.map((b) => (
                <li
                  key={b}
                  className="inline-flex items-center gap-2 rounded-full border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)] px-3.5 py-1.5"
                >
                  <span className="h-1.5 w-1.5 rounded-full bg-[color:var(--accent)]" />
                  <span className="text-[13px] font-medium text-[color:var(--fg-primary)]">
                    {b}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        </section>

        <PlatformStrip />

        <section className="mx-auto max-w-[1100px] px-6 py-32 lg:px-10">
          <p className="mb-6 text-[12px] font-semibold uppercase tracking-[0.16em] text-[color:var(--accent)]">
            产品理念
          </p>
          <h2 className="max-w-[820px] font-serif text-[clamp(34px,5vw,56px)] leading-[1.1] tracking-[-0.02em] text-[color:var(--fg-primary)]">
            一个真正会被用起来的日记,胜过一个完美却被弃用的日记。
          </h2>
          <div className="mt-16 grid grid-cols-1 gap-10 md:grid-cols-3">
            {PILLARS.map((p, i) => (
              <motion.article
                key={p.title}
                initial={reduced ? { opacity: 0 } : { opacity: 0, y: 12 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, margin: "-80px" }}
                transition={{ delay: 0.08 * i, duration: 0.5 }}
                className="rounded-2xl border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/70 p-7"
              >
                <h3 className="font-serif text-[22px] tracking-[-0.01em] text-[color:var(--fg-primary)]">
                  {p.title}
                </h3>
                <p className="mt-4 text-[15px] leading-[1.7] text-[color:var(--fg-muted)]">
                  {p.body}
                </p>
              </motion.article>
            ))}
          </div>
        </section>

        <section className="border-t border-[color:var(--border-subtle)] bg-[color:var(--surface-sunken)]">
          <div className="mx-auto max-w-[1100px] px-6 py-24 text-center lg:px-10">
            <h2 className="font-serif text-[clamp(32px,4.5vw,48px)] leading-[1.15] tracking-[-0.02em] text-[color:var(--fg-primary)]">
              今天先记,明天再读。
            </h2>
            <p className="mx-auto mt-5 max-w-[560px] text-[16px] leading-[1.7] text-[color:var(--fg-muted)]">
              免费、无需账号、iOS 上架中。数据始终留在你的设备上,直到你决定上传它。
            </p>
            <div className="mt-9 flex flex-wrap justify-center gap-3">
              <Link
                href="/download"
                className="cta-magnetic inline-flex h-12 items-center justify-center rounded-full bg-[color:var(--accent)] px-7 text-[15px] font-medium text-[color:var(--bg-warm)] hover:bg-[color:var(--accent-hover)]"
              >
                立即下载
              </Link>
              <Link
                href="/faq"
                className="inline-flex h-12 items-center justify-center rounded-full border border-[color:var(--border-default)] bg-[color:var(--surface-white)] px-6 text-[15px] font-medium text-[color:var(--fg-primary)] hover:border-[color:var(--fg-muted)]"
              >
                常见问题
              </Link>
            </div>
          </div>
        </section>

        <Footer lang="zh" />
      </main>
    </LenisProvider>
  );
}
