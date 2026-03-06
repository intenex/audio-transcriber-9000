import SwiftUI

// MARK: - App Color Theme

enum AppTheme {
    // Primary brand colors
    static let accent = Color(red: 0.35, green: 0.48, blue: 1.0)       // Vibrant blue-purple
    static let recording = Color(red: 1.0, green: 0.28, blue: 0.38)     // Warm red
    static let success = Color(red: 0.20, green: 0.78, blue: 0.55)      // Teal green
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)       // Amber
    static let processing = Color(red: 0.56, green: 0.40, blue: 1.0)    // Purple

    // Gradient for hero elements
    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.35, green: 0.48, blue: 1.0),
            Color(red: 0.56, green: 0.40, blue: 1.0),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let recordingGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.28, blue: 0.38),
            Color(red: 1.0, green: 0.45, blue: 0.25),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Subtle backgrounds
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let sidebarSelection = Color.accentColor.opacity(0.15)
}
