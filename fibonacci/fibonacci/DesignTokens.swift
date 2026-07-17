//
//  DesignTokens.swift
//  fibonacci
//
//  Centralized design system tokens
//

import SwiftUI

// MARK: - Typography

enum Typography {
    static let displayLarge = Font.system(size: 44, weight: .bold, design: .rounded)
    static let displayMedium = Font.system(size: 36, weight: .bold, design: .rounded)
    static let headlineLarge = Font.system(size: 28, weight: .bold, design: .rounded)
    static let headlineMedium = Font.system(size: 24, weight: .bold, design: .rounded)
    static let titleLarge = Font.system(size: 26, weight: .bold)
    static let titleMedium = Font.system(size: 17, weight: .semibold)
    static let titleSmall = Font.system(size: 15, weight: .semibold)
    static let bodyLarge = Font.headline
    static let bodyMedium = Font.subheadline
    static let bodySmall = Font.caption
    static let caption = Font.caption2
    static let codeLarge = Font.system(.caption, design: .monospaced)
    static let codeSmall = Font.system(size: 10, design: .monospaced)
}

// MARK: - Colors

enum Colors {
    static let backgroundTop = Color(red: 0.06, green: 0.06, blue: 0.1)
    static let backgroundBottom = Color.black

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.45)
    static let textQuaternary = Color.white.opacity(0.35)
    static let textMuted = Color.white.opacity(0.25)

    static let success = Color.green
    static let successBackground = Color.green.opacity(0.15)
    static let error = Color.red
    static let errorMuted = Color.red.opacity(0.7)

    static let cardOverlay = Color.white.opacity(0.025)
    static let cardBorder = Color.white.opacity(0.08)
    static let cardBorderHighlight = Color.white.opacity(0.25)
    static let buttonBackground = Color.white.opacity(0.08)
    static let buttonBorder = Color.white.opacity(0.12)
    static let divider = Color.white.opacity(0.1)

    static let shadowDark = Color.black.opacity(0.18)
    static let accentGlow = Color.accentColor.opacity(0.06)
    static let accentShadow = Color.accentColor.opacity(0.35)
    static let accentGradientStart = Color.accentColor.opacity(0.65)
    static let accentGradientEnd = Color.accentColor.opacity(0.35)
    static let accent = Color.accentColor
    static let clear = Color.clear
}

// MARK: - Spacing

enum Spacing {
    static let xxxl: CGFloat = 50
    static let xxl: CGFloat = 40
    static let xl: CGFloat = 32
    static let lg: CGFloat = 28
    static let md: CGFloat = 22
    static let sm: CGFloat = 18
    static let cardPadding: CGFloat = 16
    static let xs: CGFloat = 12
    static let xxs: CGFloat = 10
    static let xxxs: CGFloat = 8
    static let inline: CGFloat = 6
    static let tight: CGFloat = 5
    static let micro: CGFloat = 4
    static let hair: CGFloat = 3
}

// MARK: - Radii

enum Radii {
    static let card: CGFloat = 14
    static let button: CGFloat = 15
    static let buttonSmall: CGFloat = 11
}

// MARK: - Sizes

enum Sizes {
    static let buttonHeight: CGFloat = 56
    static let buttonHeightSmall: CGFloat = 44
    static let successIcon: CGFloat = 65
    static let graphHeight: CGFloat = 220
    static let feedMaxHeight: CGFloat = 120
    static let buttonMaxWidth: CGFloat = 340
    static let resetButtonWidth: CGFloat = 150
    static let minWindowWidth: CGFloat = 520
    static let minWindowHeight: CGFloat = 680
}

// MARK: - Shadows

enum Shadows {
    static let cardRadius: CGFloat = 10
    static let cardY: CGFloat = 5
    static let buttonRadius: CGFloat = 16
    static let buttonY: CGFloat = 6
}

// MARK: - Animations

enum Animations {
    static let buttonPress = Animation.spring(response: 0.2, dampingFraction: 0.5)
    static let buttonRelease = Animation.spring(response: 0.3, dampingFraction: 0.55)
    static let graphUpdate = Animation.easeInOut(duration: 0.15)
    static let buttonScalePressed: CGFloat = 0.93
    static let buttonDelay: Double = 0.08
}
