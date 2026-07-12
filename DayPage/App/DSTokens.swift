// DSTokens.swift — DayPage v9.0.0 design tokens.
// DO NOT EDIT by hand. Edit design-tokens/tokens.json and run `make tokens-build`.
//
// Source of truth: design-tokens/tokens.json

import SwiftUI
import UIKit

enum DSTokens {
    static let version = "9.0.0"

    enum Colors {
        /// light #FAF8F6 / dark #1A1814
        static let bgWarm = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.10196078431372549, green: 0.09411764705882353, blue: 0.0784313725490196, alpha: 1.0)
                : UIColor(red: 0.9803921568627451, green: 0.9725490196078431, blue: 0.9647058823529412, alpha: 1.0)
        })
        /// light #FFFFFF / dark #1F1C18
        static let surfaceWhite = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.12156862745098039, green: 0.10980392156862745, blue: 0.09411764705882353, alpha: 1.0)
                : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        })
        /// light #F3F0EB / dark #252118
        static let surfaceSunken = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.1450980392156863, green: 0.12941176470588237, blue: 0.09411764705882353, alpha: 1.0)
                : UIColor(red: 0.9529411764705882, green: 0.9411764705882353, blue: 0.9215686274509803, alpha: 1.0)
        })
        /// light #2B2822 / dark #F0EDE8
        static let fgPrimary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.9411764705882353, green: 0.9294117647058824, blue: 0.9098039215686274, alpha: 1.0)
                : UIColor(red: 0.16862745098039217, green: 0.1568627450980392, blue: 0.13333333333333333, alpha: 1.0)
        })
        /// light #6B6560 / dark #A39F99
        static let fgMuted = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.6392156862745098, green: 0.6235294117647059, blue: 0.6, alpha: 1.0)
                : UIColor(red: 0.4196078431372549, green: 0.396078431372549, blue: 0.3764705882352941, alpha: 1.0)
        })
        /// light #A39F99 / dark #6B6560
        static let fgSubtle = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.4196078431372549, green: 0.396078431372549, blue: 0.3764705882352941, alpha: 1.0)
                : UIColor(red: 0.6392156862745098, green: 0.6235294117647059, blue: 0.6, alpha: 1.0)
        })
        /// light #7A7269 / dark #B8B3AC
        static let fgSubtleAa = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.7215686274509804, green: 0.7019607843137254, blue: 0.6745098039215687, alpha: 1.0)
                : UIColor(red: 0.47843137254901963, green: 0.4470588235294118, blue: 0.4117647058823529, alpha: 1.0)
        })
        /// light #5D3000 / dark #C9883A
        static let accent = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.788235294117647, green: 0.5333333333333333, blue: 0.22745098039215686, alpha: 1.0)
                : UIColor(red: 0.36470588235294116, green: 0.18823529411764706, blue: 0.0, alpha: 1.0)
        })
        /// light #7A3F00 / dark #E09A45
        static let accentHover = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.8784313725490196, green: 0.6039215686274509, blue: 0.27058823529411763, alpha: 1.0)
                : UIColor(red: 0.47843137254901963, green: 0.24705882352941178, blue: 0.0, alpha: 1.0)
        })
        /// light #F5EDE3 / dark #2A1F0E
        static let accentSoft = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.16470588235294117, green: 0.12156862745098039, blue: 0.054901960784313725, alpha: 1.0)
                : UIColor(red: 0.9607843137254902, green: 0.9294117647058824, blue: 0.8901960784313725, alpha: 1.0)
        })
        /// light #E8DCCA / dark #3D2E14
        static let accentBorder = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.23921568627450981, green: 0.1803921568627451, blue: 0.0784313725490196, alpha: 1.0)
                : UIColor(red: 0.9098039215686274, green: 0.8627450980392157, blue: 0.792156862745098, alpha: 1.0)
        })
        /// light #EDE8DF / dark #2A2620
        static let borderSubtle = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.16470588235294117, green: 0.14901960784313725, blue: 0.12549019607843137, alpha: 1.0)
                : UIColor(red: 0.9294117647058824, green: 0.9098039215686274, blue: 0.8745098039215686, alpha: 1.0)
        })
        /// light #D6CEC0 / dark #38332A
        static let borderDefault = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.2196078431372549, green: 0.2, blue: 0.16470588235294117, alpha: 1.0)
                : UIColor(red: 0.8392156862745098, green: 0.807843137254902, blue: 0.7529411764705882, alpha: 1.0)
        })
        /// light #4C7A3F / dark #6AAF5A
        static let success = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.41568627450980394, green: 0.6862745098039216, blue: 0.35294117647058826, alpha: 1.0)
                : UIColor(red: 0.2980392156862745, green: 0.47843137254901963, blue: 0.24705882352941178, alpha: 1.0)
        })
        /// light #EBF3E5 / dark #1B2E18
        static let successSoft = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.10588235294117647, green: 0.1803921568627451, blue: 0.09411764705882353, alpha: 1.0)
                : UIColor(red: 0.9215686274509803, green: 0.9529411764705882, blue: 0.8980392156862745, alpha: 1.0)
        })
        /// light #A66A00 / dark #D4940A
        static let warning = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.8313725490196079, green: 0.5803921568627451, blue: 0.0392156862745098, alpha: 1.0)
                : UIColor(red: 0.6509803921568628, green: 0.41568627450980394, blue: 0.0, alpha: 1.0)
        })
        /// light #F8ECD6 / dark #2E2210
        static let warningSoft = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.1803921568627451, green: 0.13333333333333333, blue: 0.06274509803921569, alpha: 1.0)
                : UIColor(red: 0.9725490196078431, green: 0.9254901960784314, blue: 0.8392156862745098, alpha: 1.0)
        })
        /// light #A23A2E / dark #D4524A
        static let error = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.8313725490196079, green: 0.3215686274509804, blue: 0.2901960784313726, alpha: 1.0)
                : UIColor(red: 0.6352941176470588, green: 0.22745098039215686, blue: 0.1803921568627451, alpha: 1.0)
        })
        /// light #F5E1DC / dark #2E1210
        static let errorSoft = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.1803921568627451, green: 0.07058823529411765, blue: 0.06274509803921569, alpha: 1.0)
                : UIColor(red: 0.9607843137254902, green: 0.8823529411764706, blue: 0.8627450980392157, alpha: 1.0)
        })
        /// light #F0EBE3 / dark #252118
        static let heatmapEmpty = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.1450980392156863, green: 0.12941176470588237, blue: 0.09411764705882353, alpha: 1.0)
                : UIColor(red: 0.9411764705882353, green: 0.9215686274509803, blue: 0.8901960784313725, alpha: 1.0)
        })
        /// light #E6D9C3 / dark #3D2E14
        static let heatmapLow = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.23921568627450981, green: 0.1803921568627451, blue: 0.0784313725490196, alpha: 1.0)
                : UIColor(red: 0.9019607843137255, green: 0.8509803921568627, blue: 0.7647058823529411, alpha: 1.0)
        })
        /// light #C9A677 / dark #724C1E
        static let heatmapMid = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.4470588235294118, green: 0.2980392156862745, blue: 0.11764705882352941, alpha: 1.0)
                : UIColor(red: 0.788235294117647, green: 0.6509803921568628, blue: 0.4666666666666667, alpha: 1.0)
        })
        /// light #5D3000 / dark #E0A04C
        static let heatmapHigh = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.8784313725490196, green: 0.6274509803921569, blue: 0.2980392156862745, alpha: 1.0)
                : UIColor(red: 0.36470588235294116, green: 0.18823529411764706, blue: 0.0, alpha: 1.0)
        })
        /// light #E36B4A / dark #E36B4A
        static let recordingRed = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.8901960784313725, green: 0.4196078431372549, blue: 0.2901960784313726, alpha: 1.0)
                : UIColor(red: 0.8901960784313725, green: 0.4196078431372549, blue: 0.2901960784313726, alpha: 1.0)
        })
        /// light #2D1E0C / dark #2D1E0C
        static let recordingBg = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.17647058823529413, green: 0.11764705882352941, blue: 0.047058823529411764, alpha: 1.0)
                : UIColor(red: 0.17647058823529413, green: 0.11764705882352941, blue: 0.047058823529411764, alpha: 1.0)
        })
    }

    enum Fonts {
        static let display = "Space Grotesk"
        static let serif = "Fraunces"
        static let body = "Inter"
        static let mono = "JetBrains Mono"
        static let handwrite = "Caveat"
    }

    enum FontSize {
        static let hero: CGFloat = 56.0
        static let titleXl: CGFloat = 34.0
        static let titleLg: CGFloat = 30.0
        static let titleMd: CGFloat = 22.0
        static let titleSm: CGFloat = 21.0
        static let subhead: CGFloat = 19.0
        static let bodyLg: CGFloat = 16.5
        static let body: CGFloat = 16.0
        static let bodySm: CGFloat = 14.5
        static let bodyXs: CGFloat = 13.5
        static let monoMd: CGFloat = 13.0
        static let monoSm: CGFloat = 11.5
        static let monoXs: CGFloat = 11.0
        static let mono2xs: CGFloat = 10.0
        static let mono3xs: CGFloat = 9.0
    }

    enum Radii {
        static let small: CGFloat = 8.0
        static let card: CGFloat = 14.0
        static let hero: CGFloat = 18.0
        static let week: CGFloat = 22.0
        static let sheet: CGFloat = 28.0
        static let recording: CGFloat = 34.0
        static let island: CGFloat = 24.0
        static let pill: CGFloat = 999.0
    }

    enum Shadows {
        /// CSS reference: 0 1px 2px rgba(0,0,0,0.04)
        static let card = "0 1px 2px rgba(0,0,0,0.04)"
        /// CSS reference: inset 0 0.5px 0 rgba(255,255,255,0.6)
        static let pillInset = "inset 0 0.5px 0 rgba(255,255,255,0.6)"
        /// CSS reference: 0 1px 2px rgba(0,0,0,0.05)
        static let pillDrop = "0 1px 2px rgba(0,0,0,0.05)"
        /// CSS reference: 0 2px 6px rgba(60,40,15,0.08), 0 18px 32px -12px rgba(60,40,15,0.22)
        static let composer = "0 2px 6px rgba(60,40,15,0.08), 0 18px 32px -12px rgba(60,40,15,0.22)"
        /// CSS reference: 0 24px 60px -20px rgba(60,40,15,0.35)
        static let attach = "0 24px 60px -20px rgba(60,40,15,0.35)"
        /// CSS reference: 0 24px 60px -16px rgba(40,25,5,0.55)
        static let recording = "0 24px 60px -16px rgba(40,25,5,0.55)"
        /// CSS reference: 10px 0 40px -12px rgba(60,40,15,0.22)
        static let drawer = "10px 0 40px -12px rgba(60,40,15,0.22)"
    }

    enum Elevation {
        /// CSS reference: 0 1px 2px rgba(60,40,15,0.04)
        static let flat = "0 1px 2px rgba(60,40,15,0.04)"
        /// CSS reference: 0 2px 6px rgba(60,40,15,0.08), 0 12px 24px -12px rgba(60,40,15,0.14)
        static let raise = "0 2px 6px rgba(60,40,15,0.08), 0 12px 24px -12px rgba(60,40,15,0.14)"
        /// CSS reference: 0 2px 6px rgba(60,40,15,0.10), 0 24px 48px -16px rgba(60,40,15,0.28)
        static let float = "0 2px 6px rgba(60,40,15,0.10), 0 24px 48px -16px rgba(60,40,15,0.28)"

        // Dark-scheme shadow references — black-based, higher opacity
        // (warm-ink shadows disappear on dark canvases).
        /// CSS reference (dark): 0 1px 2px rgba(0,0,0,0.24)
        static let flatDark = "0 1px 2px rgba(0,0,0,0.24)"
        /// CSS reference (dark): 0 2px 6px rgba(0,0,0,0.32), 0 12px 24px -12px rgba(0,0,0,0.42)
        static let raiseDark = "0 2px 6px rgba(0,0,0,0.32), 0 12px 24px -12px rgba(0,0,0,0.42)"
        /// CSS reference (dark): 0 2px 6px rgba(0,0,0,0.36), 0 24px 48px -16px rgba(0,0,0,0.55)
        static let floatDark = "0 2px 6px rgba(0,0,0,0.36), 0 24px 48px -16px rgba(0,0,0,0.55)"
    }

    enum Spacing {
        static let cardInner: CGFloat = 20.0
        static let cardGap: CGFloat = 16.0
        static let sectionGap: CGFloat = 24.0
        static let maWeekFeed: CGFloat = 40.0
    }

    enum Motion {
        static let spring = "cubic-bezier(.2,.8,.2,1)"
        static let easeOut = "ease-out"
        /// 220ms
        static let fast: TimeInterval = 0.220
        /// 280ms
        static let medium: TimeInterval = 0.280
        /// 320ms
        static let slow: TimeInterval = 0.320
        /// 360ms
        static let island: TimeInterval = 0.360
    }

    enum Gestures {
        static let swipeRevealWidth: CGFloat = 132.0
        static let swipeOvershoot: CGFloat = 32.0
        static let swipeDamp: CGFloat = 0.18
        static let longPressMs: CGFloat = 220.0
        static let dragVsTapThreshold: CGFloat = 6.0
        static let sheetCloseThreshold: CGFloat = 80.0
    }
}
