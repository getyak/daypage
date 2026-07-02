// DSTokens.swift — DayPage v9.0.0 design tokens.
// DO NOT EDIT by hand. Edit design-tokens/tokens.json and run `make tokens-build`.
//
// Source of truth: design-tokens/tokens.json

import SwiftUI

enum DSTokens {
    static let version = "9.0.0"

    enum Colors {
        /// #FAF8F6
        static let bgWarm = Color(red: 0.9803921568627451, green: 0.9725490196078431, blue: 0.9647058823529412)
        /// #FFFFFF
        static let surfaceWhite = Color(red: 1.0, green: 1.0, blue: 1.0)
        /// #F3F0EB
        static let surfaceSunken = Color(red: 0.9529411764705882, green: 0.9411764705882353, blue: 0.9215686274509803)
        /// #2B2822
        static let fgPrimary = Color(red: 0.16862745098039217, green: 0.1568627450980392, blue: 0.13333333333333333)
        /// #6B6560
        static let fgMuted = Color(red: 0.4196078431372549, green: 0.396078431372549, blue: 0.3764705882352941)
        /// #A39F99
        static let fgSubtle = Color(red: 0.6392156862745098, green: 0.6235294117647059, blue: 0.6)
        /// #7A7269
        static let fgSubtleAa = Color(red: 0.47843137254901963, green: 0.4470588235294118, blue: 0.4117647058823529)
        /// #5D3000
        static let accent = Color(red: 0.36470588235294116, green: 0.18823529411764706, blue: 0.0)
        /// #7A3F00
        static let accentHover = Color(red: 0.47843137254901963, green: 0.24705882352941178, blue: 0.0)
        /// #F5EDE3
        static let accentSoft = Color(red: 0.9607843137254902, green: 0.9294117647058824, blue: 0.8901960784313725)
        /// #E8DCCA
        static let accentBorder = Color(red: 0.9098039215686274, green: 0.8627450980392157, blue: 0.792156862745098)
        /// #EDE8DF
        static let borderSubtle = Color(red: 0.9294117647058824, green: 0.9098039215686274, blue: 0.8745098039215686)
        /// #D6CEC0
        static let borderDefault = Color(red: 0.8392156862745098, green: 0.807843137254902, blue: 0.7529411764705882)
        /// #4C7A3F
        static let success = Color(red: 0.2980392156862745, green: 0.47843137254901963, blue: 0.24705882352941178)
        /// #EBF3E5
        static let successSoft = Color(red: 0.9215686274509803, green: 0.9529411764705882, blue: 0.8980392156862745)
        /// #A66A00
        static let warning = Color(red: 0.6509803921568628, green: 0.41568627450980394, blue: 0.0)
        /// #F8ECD6
        static let warningSoft = Color(red: 0.9725490196078431, green: 0.9254901960784314, blue: 0.8392156862745098)
        /// #A23A2E
        static let error = Color(red: 0.6352941176470588, green: 0.22745098039215686, blue: 0.1803921568627451)
        /// #F5E1DC
        static let errorSoft = Color(red: 0.9607843137254902, green: 0.8823529411764706, blue: 0.8627450980392157)
        /// #F0EBE3
        static let heatmapEmpty = Color(red: 0.9411764705882353, green: 0.9215686274509803, blue: 0.8901960784313725)
        /// #E6D9C3
        static let heatmapLow = Color(red: 0.9019607843137255, green: 0.8509803921568627, blue: 0.7647058823529411)
        /// #C9A677
        static let heatmapMid = Color(red: 0.788235294117647, green: 0.6509803921568628, blue: 0.4666666666666667)
        /// #5D3000
        static let heatmapHigh = Color(red: 0.36470588235294116, green: 0.18823529411764706, blue: 0.0)
        /// #E36B4A
        static let recordingRed = Color(red: 0.8901960784313725, green: 0.4196078431372549, blue: 0.2901960784313726)
        /// #2D1E0C
        static let recordingBg = Color(red: 0.17647058823529413, green: 0.11764705882352941, blue: 0.047058823529411764)
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
