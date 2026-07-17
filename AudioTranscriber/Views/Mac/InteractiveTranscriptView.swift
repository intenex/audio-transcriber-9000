import SwiftUI
import AppKit

struct InteractiveTranscriptView: NSViewRepresentable {
    /// Identity of the content (the recording's id). SwiftUI reuses the same
    /// NSView + Coordinator when the user switches recordings, so this is what
    /// tells the coordinator "different recording — rebuild everything".
    let contentID: String
    let segments: [TranscriptionSegment]
    let currentTime: Double
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    var speakerNames: [String: String] = [:]
    var searchQuery: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(onSeek: onSeek)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = ClickableTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        let coordinator = context.coordinator
        textView.onWordTapped = { time in
            coordinator.onSeek(time)
        }
        coordinator.textView = textView

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = scrollView.documentView as? ClickableTextView else { return }

        // CRITICAL: refresh the seek closure every update. The coordinator is
        // created once and survives recording switches; a stale closure here
        // made word-clicks play the previously viewed recording.
        coordinator.onSeek = onSeek

        if coordinator.needsRebuild(contentID: contentID, segments: segments, speakerNames: speakerNames) {
            coordinator.buildAndSetText(from: segments, speakerNames: speakerNames, in: textView)
            coordinator.lastContentID = contentID
            textView.scroll(.zero)
        }

        // Update search highlighting
        coordinator.updateSearchHighlighting(query: searchQuery)

        if isPlaying {
            coordinator.updateHighlighting(for: currentTime)
        } else {
            coordinator.clearHighlighting()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var wordRanges: [TranscriptWordRange] = []
        var highlightedRange: NSRange? = nil
        var searchHighlightedRanges: [NSRange] = []
        var lastSegmentCount: Int = -1
        var lastContentID: String = ""
        var lastSpeakerNames: [String: String] = [:]
        var lastSearchQuery: String = ""
        var onSeek: (TimeInterval) -> Void
        weak var textView: ClickableTextView?

        init(onSeek: @escaping (TimeInterval) -> Void) {
            self.onSeek = onSeek
        }

        func needsRebuild(contentID: String, segments: [TranscriptionSegment],
                          speakerNames: [String: String]) -> Bool {
            lastContentID != contentID
                || lastSegmentCount != segments.count
                || lastSpeakerNames != speakerNames
        }

        func buildAndSetText(from segments: [TranscriptionSegment], speakerNames: [String: String], in textView: ClickableTextView) {
            highlightedRange = nil
            searchHighlightedRanges = []
            lastSearchQuery = ""

            let output = TranscriptTextBuilder.build(segments: segments, speakerNames: speakerNames)
            wordRanges = output.wordRanges

            textView.textStorage?.setAttributedString(output.text)
            textView.wordRanges = output.wordRanges
            lastSegmentCount = segments.count
            lastSpeakerNames = speakerNames
        }

        func updateSearchHighlighting(query: String) {
            guard let textView = textView, let storage = textView.textStorage else { return }
            guard query != lastSearchQuery else { return }
            lastSearchQuery = query

            // Clear old search highlights
            for range in searchHighlightedRanges {
                if range.location + range.length <= storage.length {
                    storage.removeAttribute(.underlineStyle, range: range)
                    storage.removeAttribute(.underlineColor, range: range)
                }
            }
            searchHighlightedRanges = TranscriptTextBuilder.searchRanges(in: storage.string, query: query)
            for nsRange in searchHighlightedRanges {
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: NSColor.systemOrange
                ], range: nsRange)
            }
        }

        func updateHighlighting(for time: Double) {
            guard let textView = textView, let storage = textView.textStorage else { return }

            let newRange = TranscriptTextBuilder.wordRange(at: time, in: wordRanges)
            guard newRange != highlightedRange else { return }

            if let old = highlightedRange, old.location + old.length <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }

            highlightedRange = newRange
            if let new = newRange, new.location + new.length <= storage.length {
                storage.addAttribute(.backgroundColor,
                                     value: NSColor.systemYellow.withAlphaComponent(0.5),
                                     range: new)
                textView.scrollRangeToVisible(new)
            }
        }

        func clearHighlighting() {
            guard let textView = textView, let storage = textView.textStorage else { return }
            if let old = highlightedRange, old.location + old.length <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }
            highlightedRange = nil
        }
    }

    // MARK: - ClickableTextView

    class ClickableTextView: NSTextView {
        var onWordTapped: ((TimeInterval) -> Void)?
        var wordRanges: [TranscriptWordRange] = []

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let layoutManager = layoutManager,
                  let textContainer = textContainer else {
                super.mouseDown(with: event)
                return
            }

            // Convert to text container coordinates (subtract inset)
            let adjustedPoint = NSPoint(
                x: point.x - textContainerInset.width,
                y: point.y - textContainerInset.height
            )

            var fraction: CGFloat = 0
            let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            if let time = TranscriptTextBuilder.seekTime(forCharacterAt: charIndex, in: wordRanges) {
                onWordTapped?(time)
                return
            }

            super.mouseDown(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
