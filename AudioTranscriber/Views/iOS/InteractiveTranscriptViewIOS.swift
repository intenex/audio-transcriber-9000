#if os(iOS)
import SwiftUI
import UIKit

/// iOS twin of the Mac interactive transcript: UITextView + tap-to-seek +
/// playback/search highlighting, driven by the SAME TranscriptTextBuilder so
/// text, ranges, and geometry match the Mac exactly.
///
/// Carries both hard-won Mac lessons (docs/DEVELOPMENT.md): the coordinator
/// outlives selection changes, so `onSeek` is re-assigned every update and
/// content rebuilds only on an explicit `contentID` change.
struct InteractiveTranscriptViewIOS: UIViewRepresentable {
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

    func makeUIView(context: Context) -> UITextView {
        // Touching .layoutManager opts into TextKit 1 — the same geometry
        // model the Mac view uses for hit-testing.
        let textView = UITextView()
        _ = textView.layoutManager
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false

        let coordinator = context.coordinator
        coordinator.textView = textView

        let tap = UITapGestureRecognizer(target: coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator

        // CRITICAL: refresh the seek closure every update (stale closures made
        // word-taps play the previously viewed recording on the Mac).
        coordinator.onSeek = onSeek

        if coordinator.needsRebuild(contentID: contentID, segments: segments, speakerNames: speakerNames) {
            coordinator.buildAndSetText(from: segments, speakerNames: speakerNames, in: textView)
            coordinator.lastContentID = contentID
            textView.setContentOffset(.zero, animated: false)
        }

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
        weak var textView: UITextView?

        init(onSeek: @escaping (TimeInterval) -> Void) {
            self.onSeek = onSeek
        }

        func needsRebuild(contentID: String, segments: [TranscriptionSegment],
                          speakerNames: [String: String]) -> Bool {
            lastContentID != contentID
                || lastSegmentCount != segments.count
                || lastSpeakerNames != speakerNames
        }

        func buildAndSetText(from segments: [TranscriptionSegment],
                             speakerNames: [String: String], in textView: UITextView) {
            highlightedRange = nil
            searchHighlightedRanges = []
            lastSearchQuery = ""

            let output = TranscriptTextBuilder.build(segments: segments, speakerNames: speakerNames)
            wordRanges = output.wordRanges
            textView.textStorage.setAttributedString(output.text)
            lastSegmentCount = segments.count
            lastSpeakerNames = speakerNames
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView else { return }
            var point = gesture.location(in: textView)
            point.x -= textView.textContainerInset.left
            point.y -= textView.textContainerInset.top

            let layoutManager = textView.layoutManager
            let glyphIndex = layoutManager.glyphIndex(for: point, in: textView.textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            if let time = TranscriptTextBuilder.seekTime(forCharacterAt: charIndex, in: wordRanges) {
                onSeek(time)
            }
        }

        func updateSearchHighlighting(query: String) {
            guard let textView else { return }
            guard query != lastSearchQuery else { return }
            lastSearchQuery = query
            let storage = textView.textStorage

            for range in searchHighlightedRanges where range.location + range.length <= storage.length {
                storage.removeAttribute(.underlineStyle, range: range)
                storage.removeAttribute(.underlineColor, range: range)
            }
            searchHighlightedRanges = TranscriptTextBuilder.searchRanges(in: storage.string, query: query)
            for nsRange in searchHighlightedRanges {
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: UIColor.systemOrange
                ], range: nsRange)
            }
        }

        func updateHighlighting(for time: Double) {
            guard let textView else { return }
            let storage = textView.textStorage

            let newRange = TranscriptTextBuilder.wordRange(at: time, in: wordRanges)
            guard newRange != highlightedRange else { return }

            if let old = highlightedRange, old.location + old.length <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }

            highlightedRange = newRange
            if let new = newRange, new.location + new.length <= storage.length {
                storage.addAttribute(.backgroundColor,
                                     value: UIColor.systemYellow.withAlphaComponent(0.5),
                                     range: new)
                textView.scrollRangeToVisible(new)
            }
        }

        func clearHighlighting() {
            guard let textView else { return }
            let storage = textView.textStorage
            if let old = highlightedRange, old.location + old.length <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }
            highlightedRange = nil
        }
    }
}
#endif
