import SwiftUI
import AppKit

struct InteractiveTranscriptView: NSViewRepresentable {
    let segments: [TranscriptionSegment]
    let currentTime: Double
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void

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

        if coordinator.needsRebuild(for: segments) {
            coordinator.buildAndSetText(from: segments, in: textView)
        }

        if isPlaying {
            coordinator.updateHighlighting(for: currentTime)
        } else {
            coordinator.clearHighlighting()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var wordRanges: [(range: NSRange, start: TimeInterval, end: TimeInterval)] = []
        var highlightedRange: NSRange? = nil
        var lastSegmentCount: Int = -1
        let onSeek: (TimeInterval) -> Void
        weak var textView: ClickableTextView?

        init(onSeek: @escaping (TimeInterval) -> Void) {
            self.onSeek = onSeek
        }

        func needsRebuild(for segments: [TranscriptionSegment]) -> Bool {
            lastSegmentCount != segments.count
        }

        func buildAndSetText(from segments: [TranscriptionSegment], in textView: ClickableTextView) {
            wordRanges = []
            highlightedRange = nil
            let result = NSMutableAttributedString()

            // Speaker mapping: first appearance = Speaker 1, etc.
            var speakerOrder: [String] = []
            var speakerMapping: [String: Int] = [:]
            for seg in segments {
                if speakerMapping[seg.speaker] == nil {
                    speakerOrder.append(seg.speaker)
                    speakerMapping[seg.speaker] = speakerOrder.count
                }
            }

            let bodyFont = NSFont.systemFont(ofSize: 14)
            let headerFont = NSFont.boldSystemFont(ofSize: 13)
            let headerColor = NSColor.secondaryLabelColor
            let bodyColor = NSColor.labelColor

            let bodyParagraph = NSMutableParagraphStyle()
            bodyParagraph.lineSpacing = 5

            let headerParagraph = NSMutableParagraphStyle()
            headerParagraph.paragraphSpacingBefore = 20

            // Group consecutive same-speaker segments
            struct Group {
                let speaker: String
                let firstTime: TimeInterval
                var words: [(text: String, start: TimeInterval, end: TimeInterval)]
            }
            var groups: [Group] = []

            for seg in segments {
                let segWords: [(text: String, start: TimeInterval, end: TimeInterval)]
                if !seg.words.isEmpty {
                    segWords = seg.words.compactMap { w -> (String, TimeInterval, TimeInterval)? in
                        let text = w.word.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return nil }
                        return (text, w.start ?? seg.start, w.end ?? seg.end)
                    }
                } else {
                    let parts = seg.text.components(separatedBy: " ").filter { !$0.isEmpty }
                    let count = max(1, parts.count)
                    let wordDuration = (seg.end - seg.start) / Double(count)
                    segWords = parts.enumerated().map { (i, word) in
                        (word, seg.start + Double(i) * wordDuration, seg.start + Double(i + 1) * wordDuration)
                    }
                }

                if let lastIdx = groups.indices.last, groups[lastIdx].speaker == seg.speaker {
                    groups[groups.count - 1].words.append(contentsOf: segWords)
                } else {
                    groups.append(Group(speaker: seg.speaker, firstTime: seg.start, words: segWords))
                }
            }

            // Render each speaker group
            for (gi, group) in groups.enumerated() {
                let speakerNum = speakerMapping[group.speaker] ?? 1
                let ts = formatTimestamp(group.firstTime)
                let headerPara = gi == 0 ? NSMutableParagraphStyle() : headerParagraph

                let headerStr = "Speaker \(speakerNum)   [\(ts)]\n"
                result.append(NSAttributedString(string: headerStr, attributes: [
                    .font: headerFont,
                    .foregroundColor: headerColor,
                    .paragraphStyle: headerPara
                ]))

                for word in group.words {
                    guard !word.text.isEmpty else { continue }
                    let rangeStart = result.length
                    result.append(NSAttributedString(string: word.text, attributes: [
                        .font: bodyFont,
                        .foregroundColor: bodyColor,
                        .paragraphStyle: bodyParagraph
                    ]))
                    wordRanges.append((
                        range: NSRange(location: rangeStart, length: (word.text as NSString).length),
                        start: word.start,
                        end: word.end
                    ))
                    result.append(NSAttributedString(string: " ", attributes: [
                        .font: bodyFont,
                        .paragraphStyle: bodyParagraph
                    ]))
                }

                result.append(NSAttributedString(string: "\n\n"))
            }

            textView.textStorage?.setAttributedString(result)
            textView.wordRanges = wordRanges
            lastSegmentCount = segments.count
        }

        func updateHighlighting(for time: Double) {
            guard let textView = textView, let storage = textView.textStorage else { return }

            var newRange: NSRange? = nil
            for entry in wordRanges {
                if time >= entry.start && time < entry.end {
                    newRange = entry.range
                    break
                }
            }

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

        private func formatTimestamp(_ seconds: TimeInterval) -> String {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let s = Int(seconds) % 60
            return String(format: "%d:%02d:%02d", h, m, s)
        }
    }

    // MARK: - ClickableTextView

    class ClickableTextView: NSTextView {
        var onWordTapped: ((TimeInterval) -> Void)?
        var wordRanges: [(range: NSRange, start: TimeInterval, end: TimeInterval)] = []

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

            for entry in wordRanges {
                if NSLocationInRange(charIndex, entry.range) {
                    onWordTapped?(entry.start)
                    return
                }
            }

            super.mouseDown(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
