import HarnessButlerKit
import SwiftUI

/// H-5: "what's new" for a pending update. Collapsed it shows the first few changes of the newest
/// version; expanded it scrolls through every version since the installed one.
struct ReleaseNotesView: View {
    let notes: ReleaseNotes?
    let isLoading: Bool
    /// Used for the link while notes are loading or couldn't be fetched.
    let fallbackURL: URL
    @State private var expanded = Self.startExpanded
    @State private var contentHeight: CGFloat = 0

    private static var startExpanded: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--expand-notes") // UI checks
        #else
        false
        #endif
    }

    private static let collapsedItems = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notes, !notes.entries.isEmpty {
                title(notes)
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(notes.entries, id: \.version) { entry in
                                versionHeader(entry)
                                ForEach(Array(entry.blocks.enumerated()), id: \.offset) { _, block in
                                    BlockView(block: block)
                                }
                            }
                            if notes.isPartial {
                                Text("Older versions are in the full release notes.").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                    }
                    // The popover sizes to its content, so give the scroll view a definite height.
                    .frame(height: min(max(contentHeight, 40), 220))
                } else {
                    ForEach(Array(collapsedItems(notes).enumerated()), id: \.offset) { _, block in
                        BlockView(block: block).lineLimit(2)
                    }
                }
                footer(notes)
            } else if isLoading {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("loading release notes…").foregroundStyle(.secondary)
                }
            } else {
                Link("release notes ↗", destination: fallbackURL).foregroundStyle(Theme.accent)
            }
        }
    }

    private func title(_ notes: ReleaseNotes) -> some View {
        let versions = notes.entries.map(\.version)
        let range = versions.count > 1 ? "\(versions.last!) – \(versions.first!)" : "\(notes.target)"
        return Text("what's new in \(range)").font(Theme.mono(10, weight: .semibold))
    }

    private func versionHeader(_ entry: ReleaseNotes.Entry) -> some View {
        HStack(spacing: 4) {
            Text(entry.version.description).font(Theme.mono(10, weight: .semibold)).foregroundStyle(Theme.accent)
            if let date = entry.date { Text(date).foregroundStyle(.tertiary) }
        }
        .padding(.top, 4)
    }

    /// The newest version's first bullets (headings dropped to save room).
    private func collapsedItems(_ notes: ReleaseNotes) -> [ReleaseNotes.Block] {
        Array(notes.entries.flatMap(\.blocks).filter { if case .item(_, 0) = $0 { true } else { false } }.prefix(Self.collapsedItems))
    }

    private func footer(_ notes: ReleaseNotes) -> some View {
        let total = notes.entries.reduce(0) { $0 + $1.itemCount }
        let hidden = total - min(total, Self.collapsedItems)
        return HStack(spacing: 10) {
            if hidden > 0 || notes.entries.count > 1 {
                Button(expanded ? "show less" : "show all \(total) changes") { expanded.toggle() }
                    .buttonStyle(.link)
            }
            Link("full release notes ↗", destination: notes.fullNotesURL)
        }
        .foregroundStyle(Theme.accent)
        .padding(.top, 2)
    }
}

private struct BlockView: View {
    let block: ReleaseNotes.Block

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text).font(Theme.mono(10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
        case .item(let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(level == 0 ? "•" : "◦").foregroundStyle(.tertiary)
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 10)
        case .paragraph(let text):
            Text(Self.inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inline markdown only (bold, code, links); block syntax was already parsed.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
