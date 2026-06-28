"use client";

import { motion, useTransform, type MotionValue } from "framer-motion";
import { ActCopy } from "./ActCopy";
import { IPhoneFrame } from "./IPhoneFrame";
import { ScrollScene } from "./ScrollScene";

const COPY = [
  {
    title: "At 2am, the day gets read.",
    body: "Every memo from the past 24 hours is fed to the AI compiler — voice transcripts, half-thoughts, photo captions, EXIF, your weather and your steps.",
  },
  {
    title: "Threads emerge.",
    body: "People you saw. Places you walked. Ideas that kept resurfacing. The compiler finds the through-line without you having to draft it.",
  },
  {
    title: "A diary you'll actually re-read.",
    body: "A title. A subtitle. Two or three paragraphs that sound like you. Tomorrow morning's coffee read — already on your phone.",
  },
];

export function CompileSection() {
  return (
    <ScrollScene
      id="compile"
      tone="sunken"
      label="Act 2 · Compile"
      copy={(progress) => <ActCopy items={COPY} progress={progress} />}
      stage={(progress) => (
        <IPhoneFrame width={320}>
          <CompileMockScreen progress={progress} />
        </IPhoneFrame>
      )}
    />
  );
}

const RAW_LINES = [
  "09:14 — caught the rain, reminded me of tokyo",
  "11:02 — wiki idea: entity preview next to name?",
  "13:47 — pastel de nata #427, worth the line",
  "18:30 — joão moving to madeira next month",
];

function CompileMockScreen({ progress }: { progress: MotionValue<number> }) {
  // Phase A 0.00–0.33  raw fragments visible, then dissolve
  // Phase B 0.33–0.66  compiled card title + paragraphs stagger in
  // Phase C 0.66–1.00  timestamp chip fades in

  const rawOpacity = useTransform(progress, [0, 0.05, 0.25, 0.34], [0, 1, 1, 0]);
  const rawBlur = useTransform(progress, [0.18, 0.34], [0, 6]);
  const rawBlurStr = useTransform(rawBlur, (b) => `blur(${b}px)`);

  const cardOpacity = useTransform(progress, [0.32, 0.4, 0.95, 1], [0, 1, 1, 1]);
  const cardY = useTransform(progress, [0.32, 0.42], [16, 0]);

  const titleOpacity = useTransform(progress, [0.34, 0.42], [0, 1]);
  const titleY = useTransform(progress, [0.34, 0.42], [10, 0]);

  const p1Opacity = useTransform(progress, [0.42, 0.5], [0, 1]);
  const p1Y = useTransform(progress, [0.42, 0.5], [10, 0]);

  const p2Opacity = useTransform(progress, [0.5, 0.58], [0, 1]);
  const p2Y = useTransform(progress, [0.5, 0.58], [10, 0]);

  const listOpacity = useTransform(progress, [0.58, 0.66], [0, 1]);
  const listY = useTransform(progress, [0.58, 0.66], [10, 0]);

  const stampOpacity = useTransform(progress, [0.7, 0.8], [0, 1]);
  const stampScale = useTransform(progress, [0.7, 0.84], [0.9, 1]);

  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        flexDirection: "column",
        padding: "56px 18px 18px",
        gap: 12,
        fontFamily: "var(--font-inter), system-ui",
      }}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
        <span style={{ fontSize: 11, color: "var(--fg-subtle-aa)", letterSpacing: 1 }}>
          SAT · JUN 28
        </span>
        <span
          style={{
            fontFamily: "var(--font-fraunces), serif",
            fontSize: 22,
            fontWeight: 600,
            color: "var(--fg-primary)",
            letterSpacing: -0.5,
          }}
        >
          Today
        </span>
      </div>

      <div style={{ position: "relative", flex: 1 }}>
        <motion.div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            gap: 8,
            opacity: rawOpacity,
            filter: rawBlurStr,
          }}
        >
          {RAW_LINES.map((line) => (
            <div
              key={line}
              style={{
                padding: "8px 11px",
                borderRadius: 10,
                background: "rgba(255,255,255,0.7)",
                border: "1px dashed var(--border-subtle)",
                fontSize: 11,
                color: "var(--fg-muted)",
                lineHeight: 1.4,
              }}
            >
              {line}
            </div>
          ))}
        </motion.div>

        <motion.div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            opacity: cardOpacity,
            y: cardY,
          }}
        >
          <div
            style={{
              padding: "14px 14px 12px",
              borderRadius: 16,
              background: "var(--surface-white)",
              border: "1px solid var(--border-subtle)",
              boxShadow: "0 12px 28px -16px rgba(43,40,34,0.18)",
              display: "flex",
              flexDirection: "column",
              gap: 8,
            }}
          >
            <motion.h4
              style={{
                opacity: titleOpacity,
                y: titleY,
                fontFamily: "var(--font-fraunces), serif",
                fontSize: 17,
                fontWeight: 600,
                color: "var(--fg-primary)",
                letterSpacing: -0.3,
                lineHeight: 1.2,
                margin: 0,
              }}
            >
              A Saturday folded around the rain
            </motion.h4>

            <motion.p
              style={{
                opacity: p1Opacity,
                y: p1Y,
                fontSize: 11.5,
                lineHeight: 1.55,
                color: "var(--fg-primary)",
                margin: 0,
              }}
            >
              The morning came in soft and gray. Coffee at Heden while the rain
              moved across the window — it pulled Tokyo back into the room,
              that flight-eve quiet I keep returning to.
            </motion.p>

            <motion.p
              style={{
                opacity: p2Opacity,
                y: p2Y,
                fontSize: 11.5,
                lineHeight: 1.55,
                color: "var(--fg-primary)",
                margin: 0,
              }}
            >
              Walked to Belém in the afternoon. The wiki idea kept tugging at
              me, and João's news came late: Madeira, next month.
            </motion.p>

            <motion.ul
              style={{
                opacity: listOpacity,
                y: listY,
                listStyle: "none",
                padding: 0,
                margin: 0,
                display: "flex",
                flexDirection: "column",
                gap: 4,
              }}
            >
              {[
                "Heden — open till midnight tonight",
                "Wiki: entity preview prototype",
                "Plan a Lisbon coworking week",
              ].map((line) => (
                <li
                  key={line}
                  style={{
                    fontSize: 11,
                    color: "var(--fg-muted)",
                    paddingLeft: 10,
                    position: "relative",
                    lineHeight: 1.45,
                  }}
                >
                  <span
                    style={{
                      position: "absolute",
                      left: 0,
                      top: 6,
                      width: 4,
                      height: 4,
                      borderRadius: 999,
                      background: "var(--accent)",
                    }}
                  />
                  {line}
                </li>
              ))}
            </motion.ul>
          </div>

          <motion.div
            style={{
              opacity: stampOpacity,
              scale: stampScale,
              marginTop: 10,
              alignSelf: "flex-end",
              display: "inline-flex",
              alignItems: "center",
              gap: 6,
              padding: "5px 10px",
              borderRadius: 999,
              background: "var(--accent-soft)",
              border: "1px solid var(--accent-border)",
              fontSize: 10,
              color: "var(--accent)",
              letterSpacing: 0.4,
              fontWeight: 500,
            }}
          >
            <span
              style={{
                width: 5,
                height: 5,
                borderRadius: 999,
                background: "var(--accent)",
              }}
            />
            02:14 AM · compiled
          </motion.div>
        </motion.div>
      </div>
    </div>
  );
}
