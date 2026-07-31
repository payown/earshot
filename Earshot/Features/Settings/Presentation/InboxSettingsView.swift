import SwiftUI

/// Settings → Inbox: how many episodes seed the inbox on subscribe, and the
/// opt-in-only membership rule. Extracted from the former single Settings form.
struct InboxSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    // Inbox seed-on-subscribe options. 0 = "None" (nothing surfaces on
    // subscribe); the "All" sentinel seeds the whole backlog.
    private static let inboxSeedOptions: [(label: String, value: Int)] = [
        ("None", 0),
        ("1", 1),
        ("3", 3),
        ("5", 5),
        ("10", 10),
        ("All", SettingsDefault.inboxDefaultCountAll),
    ]

    private var inboxSeedAdjustableOptions: [AdjustableOptionPicker<Int>.Option] {
        Self.inboxSeedOptions.map {
            .init(value: $0.value, title: $0.label, spoken: inboxSeedAccessibilityLabel(for: $0))
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                AdjustableOptionPicker(
                    "Inbox episodes per new podcast",
                    options: inboxSeedAdjustableOptions,
                    selection: $settings.inboxDefaultCount,
                    hint: "How many recent episodes appear in the inbox when you add a new podcast. Flick up for more."
                )

                // The section footer below explains this toggle; a matching hint
                // would make VoiceOver read the same sentence twice.
                Toggle("Opt-in podcasts only", isOn: $settings.inboxOptInOnly)
            } footer: {
                // No section header: the "Inbox" navigation title already names the
                // screen, so a matching header would be a redundant VoiceOver
                // heading stop.
                Text("Opt-in podcasts only: when on, new episodes only reach the inbox for podcasts you've explicitly included.")
            }
        }
        .navigationTitle("Inbox")
    }

    /// Spells out the terse picker labels ("3" → "3 episodes") for VoiceOver, and
    /// gives the sentinels natural phrasings.
    private func inboxSeedAccessibilityLabel(for option: (label: String, value: Int)) -> String {
        switch option.value {
        case 0: return "None"
        case 1: return "1 episode"
        case SettingsDefault.inboxDefaultCountAll: return "All episodes"
        default: return "\(option.value) episodes"
        }
    }
}
