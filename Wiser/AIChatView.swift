//
//  AIChatView.swift
//  Wiser
//
//  Created by Marlin on 01/11/2026.
//

import SwiftUI
import SwiftData

/// AI to talk to about the user's focus, as long as they like, with their own OpenAI API key (user, 2026-11-01:
/// "应该是让用户自己填API key最好"): Cue's conversation, brought over. Until a key is in, what it takes and where the
/// questions go.
@available(iOS 27.1, *)
struct AIChatView<Background: View>: View {
    var tint: Color
    /// What the page stands on.
    @ViewBuilder var background: () -> Background
    @State private var hasKey = OpenAIKey.value != nil

    var body: some View {
        Group {
            if hasKey {
                Conversation(hasKey: $hasKey)
            } else {
                KeySetup(tint: tint, hasKey: $hasKey)
            }
        }
        .background {
            background()
        }
        .navigationTitle("Ask AI")
        .navigationBarTitleDisplayMode(.inline)
        // The tab says which page this is; the title stays for VoiceOver.
        .toolbar(removing: .title)
    }
}

/// The conversation: the user's questions on the right, AI's answers the width of the page. A question goes up to the
/// top of the screen as it is sent, and the answer is written under it, the conversation not following it down, as in
/// Cue and in ChatGPT's app: an answer can be read from its first line however fast it comes.
@available(iOS 27.1, *)
private struct Conversation: View {
    @Binding var hasKey: Bool
    /// Where the bars run down the side of the screen, as on iPhone Duo's cover screen.
    @Environment(\.toolbarVerticalEdge) private var verticalBars
    @Query(sort: \FocusSession.startDate) private var sessions: [FocusSession]
    @State private var position = ScrollPosition(idType: Chat.Message.ID.self)
    /// The question last asked since the page was opened. It and what follows take at least the screen between the
    /// bars, room for it to be lifted to the top however short its answer, until the next one is asked.
    @State private var asked: Chat.Message.ID?
    /// The screen between the bars, for the question last asked and what follows it.
    @State private var room: CGFloat = 0
    @State private var focused = false
    /// Whether the keyboard is up, and the safe area's bottom without it.
    @State private var keyboardUp = false
    @State private var safeBottom: CGFloat = 0
    @State private var confirmingDelete = false
    @State private var managingKey = false
    /// Whether the conversation is scrolled to its end, give or take a few points.
    @State private var atEnd = true
    private let chat = FocusChat.shared

    private var draft: Binding<String> {
        Binding { chat.draft } set: { chat.draft = $0 }
    }

    var body: some View {
        let messages = chat.messages
        // Where the question last asked begins, if it was asked since the page was opened.
        let split = asked.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.endIndex
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(messages[..<split]) { message in
                    row(message, writing: false)
                        .padding(.top, Self.gap(above: message, first: messages.first?.id))
                }
                latest(messages, split: split)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.horizontal, 22, for: .scrollContent)
        .contentMargins(.vertical, 16, for: .scrollContent)
        .scrollPosition($position)
        // Opened at the end of what was written, from the first frame. At its end with nothing being written, it
        // keeps its end in sight as the keyboard comes and goes, as a messenger does; otherwise it keeps its place,
        // so an answer is written on below what is being read.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(atEnd && !chat.answering ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y >= geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.height - 10
        } action: { _, end in
            atEnd = end
        }
        // The scroll view's container is what's between the bars and the margins already.
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
            room = height
        }
        // The keyboard goes only when it is dragged down, not as the conversation is read.
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if messages.isEmpty {
                ContentUnavailableView("No Questions Yet", systemImage: "sparkles")
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.5), value: messages.isEmpty)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatBar(text: draft, answering: chat.answering, focused: $focused,
                    onSend: { send(draft.wrappedValue) }, onStop: chat.stop)
                .frame(maxWidth: 640)
                .padding(.horizontal, keyboardUp ? ChatBar.insetOverKeyboard : sideInset)
                .frame(maxWidth: .infinity)
                .padding(.bottom, keyboardUp ? ChatBar.insetOverKeyboard : bottomInset)
        }
        // The safe area's bottom as it is without the keyboard: the home indicator's.
        .background {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
                .ignoresSafeArea(.keyboard)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.smooth) { keyboardUp = true }
            // At its end, the end comes up over the keyboard with it, as in a messenger, rather than going under it.
            if atEnd && !chat.answering {
                DispatchQueue.main.async {
                    withAnimation(.smooth) { position.scrollTo(edge: .bottom) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.smooth) { keyboardUp = false }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("API Key", systemImage: "key") { managingKey = true }
            }
            // Always there, and greyed out with nothing to delete; it asks first.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete Conversation", systemImage: "trash") { confirmingDelete = true }
                    .disabled(messages.isEmpty)
                    .confirmationDialog("Delete Conversation", isPresented: $confirmingDelete, titleVisibility: .hidden) {
                        Button("Delete Conversation", role: .destructive) {
                            chat.clear()
                            asked = nil
                        }
                    } message: {
                        Text("This conversation will be deleted.")
                    }
            }
        }
        .sheet(isPresented: $managingKey) {
            KeySheet(hasKey: $hasKey)
        }
        // The caret in the text's own colour, never the system's blue.
        .tint(.primary)
        .onAppear {
            chat.open()
            // Opened again while an answer is being written: its question back at the top, the answer going on under it.
            if chat.answering, let question = chat.messages.last(where: { $0.role == .user })?.id {
                asked = question
                DispatchQueue.main.async { position.scrollTo(id: question, anchor: .top) }
            }
        }
    }

    /// The question last asked and what follows it, kept at least the screen tall; or, with none, why the last answer
    /// didn't come, if it didn't.
    @ViewBuilder
    private func latest(_ messages: [Chat.Message], split: Int) -> some View {
        if split < messages.endIndex {
            VStack(alignment: .leading, spacing: Self.answerGap) {
                ForEach(messages[split...]) { message in
                    row(message, writing: chat.answering && message.id == messages.last?.id)
                }
                failure
            }
            .frame(minHeight: room, alignment: .top)
            .padding(.top, split == 0 ? 0 : Self.questionGap)
        } else {
            failure
                .padding(.top, Self.answerGap)
        }
    }

    @ViewBuilder
    private func row(_ message: Chat.Message, writing: Bool) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(.fill.secondary, in: .rect(cornerRadius: 20, style: .continuous))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20, style: .continuous))
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 56)
                .id(message.id)
        case .assistant:
            Group {
                if message.text.isEmpty {
                    // Until its first words come.
                    ThinkingText()
                } else {
                    StreamedText(text: message.text, writing: writing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(message.id)
        }
    }

    /// Why the last answer didn't come, if it didn't.
    @ViewBuilder
    private var failure: some View {
        if let failure = chat.failure {
            Text(failure)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Asks the question and lifts it to the top. The keyboard goes, so the answer has the screen, as in Cue.
    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chat.answering else { return }
        draft.wrappedValue = ""
        focused = false
        guard let id = chat.send(question, records: FocusRecords.lines(sessions)) else { return }
        asked = id
        // An update after the question and its room are in: sent in the same one, the rise found nowhere to go.
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.5)) { position.scrollTo(id: id, anchor: .top) }
        }
    }

    /// Where the bars run down the side, the field sits as they do, as far in from the screen's sides and its bottom
    /// as they are, concentric with its corners: its foot level with the tabs', as Safari keeps its address there.
    /// Elsewhere, above the tabs, as iOS's own bottom field.
    private var sideInset: CGFloat {
        verticalBars != nil ? Self.columnInset : ChatBar.inset
    }

    private var bottomInset: CGFloat {
        verticalBars != nil ? Self.columnInset - safeBottom : ChatBar.insetOverKeyboard
    }

    /// How far in from the screen's edges the bars down its side sit (measured on iPhone Duo's cover screen).
    private static let columnInset: CGFloat = 24

    /// Space between a question and its answer, and above a question.
    private static let answerGap: CGFloat = 20
    private static let questionGap: CGFloat = 36

    /// The space above a message: an answer's, close under its question; a question's, further from the answer before
    /// it; none above the first.
    private static func gap(above message: Chat.Message, first: Chat.Message.ID?) -> CGFloat {
        if message.role == .assistant { return answerGap }
        return message.id == first ? 0 : questionGap
    }
}

/// The question being written, in one glass field the width of the page; once there is something to send, a black
/// send button sits inside it at its end, as Siri's does, and the same button stops an answer being written: Cue's.
private struct ChatBar: View {
    @Binding var text: String
    var answering: Bool
    @Binding var focused: Bool
    var onSend: () -> Void
    var onStop: () -> Void
    @FocusState private var fieldFocused: Bool

    /// iOS's own bottom field: 48 pt tall, 27.5 pt in from the sides at rest, and 8 pt with the keyboard up, lining up
    /// with the keys and above them (measured in Messages by Cue).
    static let height: CGFloat = 48
    static let inset: CGFloat = 27.5
    static let insetOverKeyboard: CGFloat = 8

    var body: some View {
        let ready = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let inField = ready || answering
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your focus", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($fieldFocused)
                    .padding(.vertical, 13)
                // Room for the send button, which lies over the glass rather than in it: anything in the glass, the
                // glass drew in its own vibrant grey.
                if inField { Color.clear.frame(width: 38, height: 28).padding(.vertical, 10) }
            }
            .padding(.leading, 20)
            .padding(.trailing, inField ? 10 : 20)
            .frame(minHeight: Self.height)
            .contentShape(.rect(cornerRadius: Self.height / 2, style: .continuous))
            .onTapGesture { fieldFocused = true }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.height / 2, style: .continuous))
        }
        .overlay(alignment: .bottomTrailing) {
            if inField {
                sendButton
                    .padding([.trailing, .bottom], 10 - Self.reach)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: inField)
        .onChange(of: fieldFocused) { _, now in if focused != now { focused = now } }
        .onChange(of: focused, initial: true) { _, now in if fieldFocused != now { fieldFocused = now } }
    }

    /// How far beyond the send button's pill a touch still presses it.
    private static let reach: CGFloat = 8

    /// Black, a short pill, inside the field at its end, with a heavy arrow: Siri's. Black without glass over it,
    /// which turned it grey, and the same shape however it is pressed.
    private var sendButton: some View {
        Button {
            if answering { onStop() } else { onSend() }
        } label: {
            Image(systemName: answering ? "stop.fill" : "arrow.up")
                .font(.system(size: answering ? 12 : 15, weight: .bold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 38, height: 28)
                .background(Color.primary, in: .capsule)
                // A finger's width all round, 54 × 44, though the pill is small.
                .padding(Self.reach)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(answering ? "Stop" : "Send")
    }
}

/// Before anything is asked: what the conversation takes, the user's own OpenAI API key, and where the questions go
/// with it, said plainly, as App Review asks before anyone's data goes to an AI (5.1.2(i)). Putting a key in is the
/// user's go-ahead.
private struct KeySetup: View {
    var tint: Color
    @Binding var hasKey: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var key = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(tint.ink(for: colorScheme))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ask AI about your focus")
                        .font(.title2.weight(.semibold))
                    Text("How your week went, when you focus best, how to plan tomorrow: AI answers from your focus records.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("OpenAI API key", text: $key)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    Button(action: save) {
                        Text("Use This Key")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(tint.ink(for: colorScheme))
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Your questions and your focus records go to OpenAI with your key, and OpenAI bills your account for them. The key stays on this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                    Label("Get a key from OpenAI", systemImage: "arrow.up.right")
                        .font(.footnote.weight(.medium))
                }
                .tint(tint.ink(for: colorScheme))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        OpenAIKey.set(key)
        key = ""
        fieldFocused = false
        withAnimation(.smooth) { hasKey = OpenAIKey.value != nil }
    }
}

/// The key in use: put another in, or take it out.
private struct KeySheet: View {
    @Binding var hasKey: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var confirmingRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("In use", value: "••••" + String((OpenAIKey.value ?? "").suffix(4)))
                    SecureField("New key", text: $key)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Your questions and your focus records go to OpenAI with your key, and OpenAI bills your account for them. The key stays on this iPhone.")
                }
                Section {
                    Button("Remove Key", role: .destructive) { confirmingRemove = true }
                        .confirmationDialog("Remove Key", isPresented: $confirmingRemove, titleVisibility: .hidden) {
                            Button("Remove Key", role: .destructive) {
                                FocusChat.shared.stop()
                                OpenAIKey.set("")
                                hasKey = false
                                dismiss()
                            }
                        } message: {
                            Text("AI can't answer until you put a key in again.")
                        }
                }
            }
            .navigationTitle("OpenAI API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        OpenAIKey.set(key)
                        dismiss()
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
