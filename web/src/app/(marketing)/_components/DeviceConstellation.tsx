"use client";

import { motion, useReducedMotion } from "framer-motion";
import { IPhoneFrame, TodayMockScreen } from "./IPhoneFrame";
import { MacBookFrame, MacBookArchiveMock } from "./MacBookFrame";
import { WatchFrame, WatchGlanceMock } from "./WatchFrame";

/**
 * Three-device constellation for the hero. Desktop shows MacBook behind,
 * iPhone in front, Watch floating to the upper-left. Mobile shows iPhone
 * only — the other surfaces appear in the PlatformStrip below.
 */
export function DeviceConstellation() {
  const reduced = useReducedMotion();

  return (
    <div className="relative w-full">
      {/* md+ : full constellation */}
      <div className="relative hidden h-[460px] md:block lg:h-[520px]">
        {/* MacBook — sits in the back, anchored right */}
        <motion.div
          initial={reduced ? { opacity: 0 } : { opacity: 0, y: 30, rotate: -2 }}
          animate={
            reduced
              ? { opacity: 1 }
              : { opacity: 1, y: [0, -4, 0], rotate: 0 }
          }
          transition={
            reduced
              ? { duration: 0.3 }
              : {
                  opacity: { type: "spring", stiffness: 80, damping: 18, delay: 0.7 },
                  y: { duration: 6, repeat: Infinity, ease: "easeInOut", delay: 1.5 },
                }
          }
          className="absolute"
          style={{
            right: 0,
            top: 60,
            transform: "perspective(1400px) rotateY(-8deg) rotateX(4deg)",
            transformOrigin: "right center",
          }}
        >
          <div className="hidden lg:block">
            <MacBookFrame width={520}>
              <MacBookArchiveMock />
            </MacBookFrame>
          </div>
          <div className="block lg:hidden">
            <MacBookFrame width={400}>
              <MacBookArchiveMock />
            </MacBookFrame>
          </div>
        </motion.div>

        {/* iPhone — front-center, slight tilt */}
        <motion.div
          initial={reduced ? { opacity: 0 } : { opacity: 0, x: 30, y: 20 }}
          animate={reduced ? { opacity: 1 } : { opacity: 1, x: 0, y: 0 }}
          transition={
            reduced
              ? { duration: 0.3 }
              : { type: "spring", stiffness: 90, damping: 18, delay: 1.0 }
          }
          className="absolute"
          style={{
            left: "10%",
            bottom: 0,
            transform: "rotate(-3deg)",
          }}
        >
          <div className="hidden lg:block">
            <IPhoneFrame width={260}>
              <TodayMockScreen />
            </IPhoneFrame>
          </div>
          <div className="block lg:hidden">
            <IPhoneFrame width={210}>
              <TodayMockScreen />
            </IPhoneFrame>
          </div>
        </motion.div>

        {/* Watch — floats upper-left of the iPhone */}
        <motion.div
          initial={reduced ? { opacity: 0 } : { opacity: 0, scale: 0.85, y: -10 }}
          animate={
            reduced
              ? { opacity: 1 }
              : { opacity: 1, scale: 1, y: [0, -6, 0] }
          }
          transition={
            reduced
              ? { duration: 0.3 }
              : {
                  opacity: { type: "spring", stiffness: 110, damping: 16, delay: 1.3 },
                  scale: { type: "spring", stiffness: 110, damping: 16, delay: 1.3 },
                  y: { duration: 4.5, repeat: Infinity, ease: "easeInOut", delay: 2 },
                }
          }
          className="absolute"
          style={{
            left: 0,
            top: 20,
            transform: "rotate(-6deg)",
          }}
        >
          <div className="hidden lg:block">
            <WatchFrame width={150}>
              <WatchGlanceMock />
            </WatchFrame>
          </div>
          <div className="block lg:hidden">
            <WatchFrame width={120}>
              <WatchGlanceMock />
            </WatchFrame>
          </div>
        </motion.div>
      </div>

      {/* <md : iPhone only, centered */}
      <div className="flex h-[420px] items-center justify-center md:hidden">
        <motion.div
          initial={reduced ? { opacity: 0 } : { opacity: 0, y: 20, rotate: 1 }}
          animate={reduced ? { opacity: 1 } : { opacity: 1, y: 0, rotate: -1 }}
          transition={
            reduced
              ? { duration: 0.3 }
              : { type: "spring", stiffness: 90, damping: 18, delay: 0.8 }
          }
        >
          <IPhoneFrame width={240}>
            <TodayMockScreen />
          </IPhoneFrame>
        </motion.div>
      </div>
    </div>
  );
}
