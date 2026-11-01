//
//  StreamedText.swift
//  Wiser
//
//  Created by Marlin on 01/11/2026.
//

import SwiftUI
import UIKit

/// An answer as AI writes it, as Cue writes its own. Its words come over the network in bursts, a dozen characters and
/// then nothing for a tenth of a second, so each burst is spread over about as long as the last one took to come, and
/// each character comes into focus as it arrives: the answer flows on at the pace it is written instead of jumping a
/// dozen characters at a time.
struct StreamedText: View {
    let text: String
    /// Whether more is coming. Text there before it began comes in at once.
    var writing: Bool

    /// When each character comes in, by its place in the text's UTF-16 (as the text's layout counts characters), in
    /// seconds since the reference date.
    @State private var times: [TimeInterval] = []
    /// When the last burst came.
    @State private var lastBurst: TimeInterval = 0
    /// Whether every character is in and nothing more is coming: the text is then one to select words in.
    @State private var settled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Lines set as `SelectableText` sets them, so the answer doesn't move as it turns into one once written.
    @ScaledMetric(relativeTo: .body) private var lineHeight = SelectableText.lineHeight

    init(text: String, writing: Bool) {
        self.text = text
        self.writing = writing
        _settled = State(initialValue: !writing)
    }

    var body: some View {
        let plain = Text(text).lineHeight(.exact(points: lineHeight))
        if !writing && (settled || reduceMotion) {
            // Written and still: words in it can be selected.
            SelectableText(text: text)
        } else if reduceMotion {
            // With Reduce Motion on, the text simply grows as it comes.
            plain
        } else {
            TimelineView(.animation(paused: settled)) { context in
                plain.textRenderer(StreamRenderer(times: times, paragraphs: paragraphs,
                                                  now: context.date.timeIntervalSinceReferenceDate))
            }
            .onChange(of: text.utf16.count, initial: true) { arrived(making: text.utf16.count) }
            .task(id: writing) {
                guard !writing else { settled = false; return }
                let rest = (times.last ?? 0) + StreamRenderer.fade - Date.now.timeIntervalSinceReferenceDate
                if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
                if !Task.isCancelled { settled = true }
            }
        }
    }

    /// Where each paragraph with characters in it begins, in UTF-16.
    private var paragraphs: [Int] {
        var starts: [Int] = []
        var start = 0
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A {
            if offset > start { starts.append(start) }
            start = offset + 1
        }
        if text.utf16.count > start { starts.append(start) }
        return starts
    }

    /// Characters have just come, making the text `total` long.
    private func arrived(making total: Int) {
        let count = total - times.count
        guard count > 0 else { return }
        // Already there: in at once.
        guard writing else {
            times += Array(repeating: 0, count: count)
            return
        }
        let now = Date.now.timeIntervalSinceReferenceDate
        settled = false
        // Spread over the time since the last burst, between 20 and 200 ms; and never more than 0.3 s behind what has
        // come.
        let start = max(now, times.last ?? 0)
        let span = start - now > 0.3 ? 0.02 : min(max(now - lastBurst, 0.02), 0.2)
        times += (1...count).map { start + span * Double($0) / Double(count) }
        lastBurst = now
    }
}

/// Draws each character of a streamed answer once its time has come, coming into focus over a quarter of a second:
/// from a soft blur and nothing to sharp and full.
nonisolated struct StreamRenderer: TextRenderer {
    var times: [TimeInterval]
    /// Where each paragraph with characters in it begins in the text, in UTF-16.
    var paragraphs: [Int]
    var now: TimeInterval

    static let fade = 0.25

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // The layout counts characters from the start of each paragraph, so the paragraphs are counted off as their
        // lines go by, a line beginning no further on than the last one ended being a new paragraph's, and each
        // character's place in the whole text found from its paragraph's start. Paragraphs with no characters have no
        // runs, and are not counted.
        guard let zero = layout.first?.first?.characterIndices.first else { return }
        var paragraph = 0
        var last = -1
        for line in layout {
            guard let begin = line.first?.characterIndices.first else { continue }
            if zero.distance(to: begin) <= last, paragraph + 1 < paragraphs.count {
                paragraph += 1
                last = -1
            }
            let start = paragraphs.isEmpty ? 0 : paragraphs[paragraph]
            for run in line {
                if let end = run.characterIndices.last { last = max(last, zero.distance(to: end)) }
                // A run all in draws whole.
                if let end = run.characterIndices.last, progress(start + zero.distance(to: end)) >= 1 {
                    context.draw(run)
                    continue
                }
                for slice in run {
                    guard let index = slice.characterIndices.first else { continue }
                    let p = progress(start + zero.distance(to: index))
                    guard p > 0 else { continue }
                    let eased = 1 - (1 - p) * (1 - p)
                    var copy = context
                    copy.opacity = eased
                    if p < 1 { copy.addFilter(.blur(radius: slice.typographicBounds.rect.height / 4 * (1 - eased))) }
                    copy.draw(slice)
                }
            }
        }
    }

    /// How far in the character at `index` is: 0 before its time, 1 once in.
    private func progress(_ index: Int) -> Double {
        guard index < times.count else { return 0 }
        return min(max((now - times[index]) / Self.fade, 0), 1)
    }
}

/// AI at work on an answer, until its first words come: the word in grey, a darker light passing over it again and
/// again, as in Cue. It shows once the question has gone up to its place, so as not to move with it.
struct ThinkingText: View {
    @State private var start = Date.now
    @State private var shown = false
    private let text = String(localized: "Thinking")

    var body: some View {
        TimelineView(.animation) { context in
            // Across the word once every 1.8 s. The light, 70% of the word's width, is wholly off the word at both
            // ends of its run, so it starts again unseen.
            let phase = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 1.8) / 1.8
            Text(text)
                .foregroundStyle(.tertiary)
                .overlay {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(colors: [.clear, .primary, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.7)
                            .offset(x: -width * 0.7 + width * 1.7 * phase)
                    }
                    .mask(Text(text))
                }
        }
        .opacity(shown ? 1 : 0)
        .task {
            try? await Task.sleep(for: .seconds(0.45))
            withAnimation(.easeOut(duration: 0.3)) { shown = true }
        }
    }
}

/// An answer once written, every line `lineHeight` tall, whose words can be selected with a long press, with the
/// system's handles and menu (Copy, Look Up, Translate, Share), as in Cue. SwiftUI's own text can be selected on iOS
/// only as a whole, so the answer long-pressed turns, for as long as something in it is selected, into UIKit's text
/// view set the same way, line for line, the word under the finger selected. The rest of the time it is SwiftUI's
/// text, light to lay out.
struct SelectableText: View {
    let text: String

    /// How tall every line of an answer is, before the 4 pt between lines, at the default text size, set alike in
    /// SwiftUI's text and UIKit's, so an answer doesn't move as it turns from one to the other.
    static let lineHeight: CGFloat = 22

    @ScaledMetric(relativeTo: .body) private var lineHeight = SelectableText.lineHeight
    /// Where the long press began that is selecting words in the text, while it is.
    @State private var selecting: CGPoint?

    var body: some View {
        Text(text)
            .lineHeight(.exact(points: lineHeight))
            .opacity(selecting == nil ? 1 : 0)
            .overlay {
                if let selecting {
                    TextView(text: text, start: selecting) { self.selecting = nil }
                }
            }
            .gesture(LongPress { selecting = $0 })
            .sensoryFeedback(.selection, trigger: selecting != nil) { _, now in now }
    }

    /// A long press, with where it began.
    private struct LongPress: UIGestureRecognizerRepresentable {
        var onPress: (CGPoint) -> Void

        func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
            let recognizer = UILongPressGestureRecognizer()
            recognizer.minimumPressDuration = 0.4
            return recognizer
        }

        func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
            if recognizer.state == .began { onPress(context.converter.localLocation) }
        }
    }

    /// UIKit's text view, for selecting: it selects the word at `start` and shows the menu for it as it comes, and goes
    /// (`onEnd`) once nothing in it is selected, or it gives up the focus.
    private struct TextView: UIViewRepresentable {
        var text: String
        var start: CGPoint
        var onEnd: () -> Void

        func makeUIView(context: Context) -> Selecting {
            let view = Selecting(usingTextLayoutManager: true)
            view.isEditable = false
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.dataDetectorTypes = []
            // Lines as tall as they are set and no taller.
            view.textLayoutManager?.usesFontLeading = false
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.attributedText = Self.attributed(text, size: context.environment.dynamicTypeSize)
            view.delegate = context.coordinator
            view.onResign = { context.coordinator.onEnd() }
            context.coordinator.onEnd = onEnd
            // Once it is in the window.
            DispatchQueue.main.async { context.coordinator.select(at: start, in: view) }
            return view
        }

        func updateUIView(_ view: Selecting, context: Context) {
            context.coordinator.onEnd = onEnd
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView view: Selecting, context: Context) -> CGSize? {
            guard let width = proposal.width, width.isFinite else { return nil }
            let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: ceil(fitted.height))
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        /// The text as SwiftUI sets it in an answer: the body font, every line `SelectableText.lineHeight` tall and
        /// 4 pt apart.
        static func attributed(_ text: String, size: DynamicTypeSize) -> NSAttributedString {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
            let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            let height = UIFontMetrics(forTextStyle: .body).scaledValue(for: SelectableText.lineHeight,
                                                                       compatibleWith: traits)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            paragraph.lineSpacing = 4
            // Lines broken where SwiftUI breaks them.
            paragraph.lineBreakStrategy = .standard
            // SwiftUI centres the text in a line taller than its font's, UIKit sets it at the line's foot: raised by
            // half the difference, the letters stand where SwiftUI's do.
            return NSAttributedString(string: text, attributes: [
                .font: body,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph,
                .baselineOffset: (height - body.lineHeight) / 2,
            ])
        }

        /// A text view that says when it gives up the focus, as when the field is tapped.
        final class Selecting: UITextView {
            var onResign: () -> Void = {}

            override func resignFirstResponder() -> Bool {
                let resigned = super.resignFirstResponder()
                if resigned { onResign() }
                return resigned
            }
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var onEnd: () -> Void = {}

            /// Selects the word at `point` and shows the system's menu for it, as a long press on text does.
            func select(at point: CGPoint, in view: UITextView) {
                guard let position = view.closestPosition(to: point),
                      let word = view.tokenizer.rangeEnclosingPosition(position, with: .word,
                                                                      inDirection: .storage(.forward))
                        ?? view.tokenizer.rangeEnclosingPosition(position, with: .word,
                                                                 inDirection: .storage(.backward))
                else { return onEnd() }
                view.becomeFirstResponder()
                view.selectedTextRange = word
                // The text view's own menu shows only for a selection made by hand; this one offers what it would,
                // from the text view, which has the focus and the selection.
                let rect = view.firstRect(for: word)
                let menu = UIEditMenuInteraction(delegate: nil)
                view.addInteraction(menu)
                menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                                   sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
            }

            /// Nothing selected any more, as after a tap: back to SwiftUI's text.
            func textViewDidChangeSelection(_ view: UITextView) {
                if view.selectedRange.length == 0 { onEnd() }
            }
        }
    }
}
