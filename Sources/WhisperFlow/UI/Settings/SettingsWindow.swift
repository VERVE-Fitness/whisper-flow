import SwiftUI
import AppKit

/// The settings window: everything a person adjusts about Whisper Flow, on this Mac,
/// without opening a browser. Menu bar → "Whisper Flow settings…", or Cmd+, .
///
/// Six sections down the left in the order somebody meets them: what dictation does, what
/// meetings do, the words the recogniser keeps getting wrong, the snippets, what all of it
/// has added up to, and which build this is.
///
/// Half of it is local and works with no connection at all (microphone, hotkeys, start at
/// login, the personal dictionary, local snippets, insights, about). The rest is Flow's,
/// and each of those blocks says so plainly when Flow cannot be reached rather than showing
/// an empty list that looks like the answer.
struct SettingsWindow: View {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case dictation
        case meetings
        case dictionary
        case snippets
        case insights
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictation: return "Dictation"
            case .meetings: return "Meetings"
            case .dictionary: return "Dictionary and phrases"
            case .snippets: return "Snippets"
            case .insights: return "Insights"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .dictation: return "mic"
            case .meetings: return "person.2.wave.2"
            case .dictionary: return "character.book.closed"
            case .snippets: return "text.badge.plus"
            case .insights: return "chart.bar"
            case .about: return "info.circle"
            }
        }
    }

    @EnvironmentObject var state: AppState
    @StateObject private var model = SettingsModel()
    @State private var selection: Section = .dictation

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(selection.title)
                        .font(.title2.bold())
                    banner
                    detail
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 860, idealWidth: 940, maxWidth: .infinity,
               minHeight: 560, idealHeight: 640, maxHeight: .infinity)
        .onAppear {
            state.refreshInputDevices()
            model.load()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dictation: DictationSettingsView(accessibility: state.accessibility)
        case .meetings: MeetingsSettingsView(model: model)
        case .dictionary: DictionarySettingsView(model: model)
        case .snippets: SnippetsSettingsView(model: model)
        case .insights: InsightsSettingsView()
        case .about: AboutSettingsView()
        }
    }

    /// One line at the top of every section when something is wrong with the connection, so
    /// an empty team list is never mistaken for an empty team.
    @ViewBuilder
    private var banner: some View {
        if selection.needsFlow {
            if !model.isConnected {
                SettingsNotice(text: "This Mac is not connected to Flow, so the team lists are not here. Everything local on this page still works.",
                               symbol: "bolt.horizontal.circle")
            } else if let error = model.error {
                SettingsNotice(text: error, symbol: "exclamationmark.triangle")
            }
        }
    }
}

extension SettingsWindow.Section {
    /// Whether the section shows anything that comes from the server.
    var needsFlow: Bool {
        switch self {
        case .meetings, .dictionary, .snippets: return true
        case .dictation, .insights, .about: return false
        }
    }
}

// MARK: - Shared pieces

/// A titled block with a sentence under the title, the shape every section is built from.
struct SettingsBlock<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }
}

struct SettingsNotice: View {
    let text: String
    var symbol: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }
}

struct SettingsEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

enum SettingsFormat {
    static func seconds(_ value: Double) -> String {
        let whole = Int(value.rounded())
        if whole < 60 { return "\(whole) seconds" }
        let minutes = whole / 60
        let rest = whole % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest)s"
    }

    static func day(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    static func number(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
}
