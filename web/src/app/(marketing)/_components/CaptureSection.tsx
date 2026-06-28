"use client";

import {
  motion,
  useMotionValueEvent,
  useTransform,
  type MotionValue,
} from "framer-motion";
import { useState } from "react";
import { ActCopy } from "./ActCopy";
import { IPhoneFrame } from "./IPhoneFrame";
import { ScrollScene } from "./ScrollScene";

const COPY = [
  {
    title: "Voice. Just talk.",
    body: "Hit the bottom bar, talk, drop. Whisper transcribes in the background — your words land in Today before you've put the phone away.",
  },
  {
    title: "Text. Half a thought is enough.",
    body: "No title, no folder, no tag. A single line at 11pm is a memo. A typo is a memo. Tomorrow's compiler will know what to do with it.",
  },
  {
    title: "Photos. The day made visible.",
    body: "Drag in screenshots, snap a pastel de nata, pick a roll from yesterday. EXIF stays attached — time, place, lens — so the wiki can stitch the geography back together later.",
  },
];

export function CaptureSection() {
  return (
    <ScrollScene
      id="capture"
      tone="warm"
      label="Act 1 · Capture"
      copy={(progress) => <ActCopy items={COPY} progress={progress} />}
      stage={(progress) => (
        <IPhoneFrame width={320}>
          <CaptureMockScreen progress={progress} />
        </IPhoneFrame>
      )}
    />
  );
}

function CaptureMockScreen({ progress }: { progress: MotionValue<number> }) {
  // Phase 1 (0.00–0.33): voice pulse
  // Phase 2 (0.33–0.66): transcript typewriter
  // Phase 3 (0.66–1.00): photo grid spring-in

  const voiceOpacity = useTransform(progress, [0, 0.05, 0.3, 0.36], [0, 1, 1, 0]);
  const voiceScale = useTransform(progress, (p) => 1 + 0.25 * Math.sin(p * 40));

  const TRANSCRIPT =
    "Caught the rain just as it hit the window. Reminded me of Tokyo, the morning before the flight back. Heden is open until midnight tonight — should swing by.";
  const transcriptOpacity = useTransform(
    progress,
    [0.3, 0.36, 0.6, 0.68],
    [0, 1, 1, 0],
  );
  const transcriptChars = useTransform(progress, [0.36, 0.62], [0, TRANSCRIPT.length]);
  // Subscribe with useMotionValueEvent so the rendered text updates per RAF
  // without triggering Framer's scroll handler restriction (the subscription is
  // on the derived motion value, not on scrollY itself).
  const [transcriptText, setTranscriptText] = useState("");
  useMotionValueEvent(transcriptChars, "change", (n) => {
    setTranscriptText(TRANSCRIPT.slice(0, Math.max(0, Math.floor(n))));
  });

  const photosOpacity = useTransform(progress, [0.6, 0.68, 1], [0, 1, 1]);
  const photo1Y = useTransform(progress, [0.6, 0.78], [40, 0]);
  const photo2Y = useTransform(progress, [0.66, 0.84], [40, 0]);
  const photo3Y = useTransform(progress, [0.72, 0.9], [40, 0]);

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
            alignItems: "center",
            justifyContent: "center",
            opacity: voiceOpacity,
          }}
        >
          <motion.div
            style={{
              width: 96,
              height: 96,
              borderRadius: 999,
              background: "var(--recording-bg)",
              display: "grid",
              placeItems: "center",
              boxShadow: "0 12px 32px -10px rgba(227,107,74,0.45)",
              scale: voiceScale,
            }}
          >
            <span
              style={{
                width: 18,
                height: 18,
                borderRadius: 4,
                background: "var(--recording-red)",
              }}
            />
          </motion.div>
          <span
            style={{
              marginTop: 18,
              fontSize: 13,
              color: "var(--fg-muted)",
              letterSpacing: 0.3,
            }}
          >
            Recording · 0:09
          </span>
          <span
            style={{
              marginTop: 4,
              fontSize: 11,
              color: "var(--fg-subtle-aa)",
            }}
          >
            Tap to stop
          </span>
        </motion.div>

        <motion.div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            opacity: transcriptOpacity,
            padding: "0 4px",
          }}
        >
          <div
            style={{
              padding: "12px 14px",
              borderRadius: 14,
              background: "var(--surface-white)",
              border: "1px solid var(--border-subtle)",
              minHeight: 140,
            }}
          >
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 6,
                marginBottom: 8,
              }}
            >
              <span
                style={{
                  width: 6,
                  height: 6,
                  borderRadius: 999,
                  background: "var(--recording-red)",
                }}
              />
              <span
                style={{
                  fontSize: 10,
                  color: "var(--fg-subtle-aa)",
                  letterSpacing: 0.6,
                }}
              >
                09:14 · voice
              </span>
            </div>
            <motion.span
              style={{
                fontSize: 13,
                lineHeight: 1.5,
                color: "var(--fg-primary)",
              }}
            >
              {transcriptText}
              <motion.span
                animate={{ opacity: [1, 0, 1] }}
                transition={{ duration: 0.9, repeat: Infinity }}
                style={{
                  display: "inline-block",
                  width: 1,
                  height: "1em",
                  background: "var(--accent)",
                  marginLeft: 2,
                  transform: "translateY(2px)",
                }}
              />
            </motion.span>
          </div>
        </motion.div>

        <motion.div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            opacity: photosOpacity,
            gap: 10,
          }}
        >
          <span
            style={{
              fontSize: 10,
              color: "var(--fg-subtle-aa)",
              letterSpacing: 0.6,
            }}
          >
            13:47 · 3 photos · Belém
          </span>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 6 }}>
            <motion.div style={{ y: photo1Y, aspectRatio: "1/1", borderRadius: 10, background: "linear-gradient(135deg,#C9A677,#7A5E3D)" }} />
            <motion.div style={{ y: photo2Y, aspectRatio: "1/1", borderRadius: 10, background: "linear-gradient(135deg,#E36B4A,#5D3000)" }} />
            <motion.div style={{ y: photo3Y, aspectRatio: "1/1", borderRadius: 10, background: "linear-gradient(135deg,#F3F0EB,#A39F99)" }} />
          </div>
          <p
            style={{
              fontSize: 11,
              color: "var(--fg-muted)",
              lineHeight: 1.4,
              marginTop: 4,
            }}
          >
            Pastel de nata #427. Worth the line.
          </p>
        </motion.div>
      </div>

      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "10px 12px",
          borderRadius: 999,
          background: "var(--surface-white)",
          border: "1px solid var(--border-subtle)",
          boxShadow: "0 6px 18px -8px rgba(43,40,34,0.18)",
        }}
      >
        <div
          style={{
            width: 28,
            height: 28,
            borderRadius: 999,
            background: "var(--accent)",
            display: "grid",
            placeItems: "center",
            color: "var(--bg-warm)",
            fontSize: 14,
            fontWeight: 700,
          }}
        >
          +
        </div>
        <span style={{ fontSize: 13, color: "var(--fg-subtle-aa)", flex: 1 }}>
          What happened?
        </span>
        <div
          style={{
            width: 24,
            height: 24,
            borderRadius: 999,
            background: "var(--recording-red)",
          }}
        />
      </div>
    </div>
  );
}
