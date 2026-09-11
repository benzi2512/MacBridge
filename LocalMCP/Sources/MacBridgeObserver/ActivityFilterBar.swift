import SwiftUI

/// One row of filters. Keep the fourth tab reachable in a narrow split pane;
/// the decorative label gives way before any option is hidden or clipped.
struct ActivityFilterBar: View {
    let feed: ActivityFeed
    let query: String
    @Binding var selection: ActivityPresentation.Filter

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Activity filter")
                picker
            }.fixedSize(horizontal: true, vertical: false)
            picker.controlSize(.small)
        }
        .help("Ungrouped shows retained actions and processes with no displayed task or context group. It does not guess a chat identity.")
    }

    private var picker: some View {
        Picker("Activity filter", selection: $selection) {
            ForEach(ActivityPresentation.Filter.allCases, id: \.self) { filter in
                Text("\(filter.rawValue) (\(feed.displayCount(query: query, filter: filter)))").tag(filter)
            }
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityLabel("Activity filter")
        .accessibilityIdentifier("activity-filter")
    }
}
