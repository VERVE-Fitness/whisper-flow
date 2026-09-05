import SwiftUI
import Charts

/// Insights: what dictation has actually added up to on this Mac over the last thirty days.
/// Read off the usage log that is already written after every dictation, so it needs no
/// connection and nothing new is recorded for it.
struct InsightsSettingsView: View {
    @State private var summary: Insights.Summary = .empty

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if summary.isEmpty {
                SettingsBlock(title: "The last 30 days") {
                    SettingsEmptyLine(text: "Nothing dictated on this Mac in the last 30 days.")
                }
            } else {
                totals
                chart(title: "Dictations a day", values: summary.days.map { Double($0.dictations) })
                chart(title: "Words a day", values: summary.days.map { Double($0.words) })
                Text("Words are counted at five characters each, which is what the log stores. Typing time saved is those words at \(Int(Insights.Summary.typingWordsPerMinute)) words a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { summary = Insights.read() }
    }

    @ViewBuilder
    private var totals: some View {
        SettingsBlock(title: "The last 30 days") {
            HStack(alignment: .top, spacing: 28) {
                tile(SettingsFormat.number(summary.dictations), "dictations")
                tile(SettingsFormat.number(summary.words), "words")
                tile(SettingsFormat.number(summary.minutesOfAudio), "minutes of talking")
                tile(SettingsFormat.number(summary.averageWordsPerDictation), "words each, on average")
            }
            Text("About \(SettingsFormat.number(summary.minutesSaved)) minutes of typing saved.")
                .font(.title3.bold())
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(minWidth: 110, alignment: .leading)
    }

    @ViewBuilder
    private func chart(title: String, values: [Double]) -> some View {
        SettingsBlock(title: title) {
            Chart(Array(zip(summary.days, values)), id: \.0.day) { day, value in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value(title, value)
                )
                .foregroundStyle(Color.accentColor)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(SettingsFormat.day(date))
                        }
                    }
                }
            }
            .frame(height: 150)
        }
    }
}
