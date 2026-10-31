// ReadableWidth.swift
// Layout helpers that keep screens readable at any window size: on iPhone and narrow iPad windows (Slide
// Over, a third of Split View) nothing changes; on wide iPad windows content sits in a centred column.

import SwiftUI

/// Shared layout limits.
enum Layout {
    /// Widest a column of text and controls gets, in points. About 75 characters of body text, the usual upper
    /// limit for comfortable reading; wider windows add space at the sides instead.
    static let readableWidth: CGFloat = 700
    /// Widest a full-width button gets on a large screen, so it still reads as one button.
    static let buttonWidth: CGFloat = 480
}

extension View {
    /// Limits this view to `Layout.readableWidth` and centres it.
    /// - Parameter maxWidth: The column width.
    /// - Returns: The view, centred in the available width.
    func readableWidth(_ maxWidth: CGFloat = Layout.readableWidth) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }

    /// For a `List` or `Form`: adds side space on wide windows so the rows form a centred column of
    /// `Layout.readableWidth`. Narrow windows get nothing extra, so they look exactly as before.
    /// - Returns: The list with adjusted margins.
    func readableList() -> some View { modifier(ReadableListMargins()) }
}

/// Measures the list's width and turns any space beyond the readable column into side space. Uses safe-area
/// padding rather than content margins, because setting content margins to 0 would remove the list's own insets.
struct ReadableListMargins: ViewModifier {
    /// The list's current width, updated on rotation and window resizing.
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let margin = Self.margin(for: width)
        return content
            .safeAreaPadding(.horizontal, margin)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The extra side space that centres a readable column.
    /// - Parameter width: The list's width.
    /// - Returns: Half the width beyond `Layout.readableWidth`, or 0 when the window isn't wider than it.
    static func margin(for width: CGFloat) -> CGFloat {
        max(0, (width - Layout.readableWidth) / 2)
    }
}

/// A scrolling page whose content fills at least the visible height, so `Spacer`s still centre short content
/// while long content (large text, short windows) scrolls instead of being cut off.
struct FillingScrollView<Content: View>: View {
    /// The page content, usually a `VStack` with `Spacer`s.
    @ViewBuilder let content: Content
    /// The visible height of the scroll view.
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(minHeight: height)
                .readableWidth()
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
}
