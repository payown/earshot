import SwiftUI
import SwiftData

/// Per-podcast settings sheet. Opened from a toolbar button on `EpisodeListView`.
/// All controls bind directly to the `Podcast` SwiftData model — changes persist
/// immediately without a save button.
///
/// Settings without a matching model field (e.g. per-podcast auto-download count)
/// are deferred to a future issue once the data agent adds them to the model.
struct PodcastSettingsView: View {
    @Bindable var podcast: Podcast
    @Environment(\.dismiss) private var dismiss

    /// Bumped each time the notification toggle is switched ON. A `.task(id:)`
    /// keyed on this token owns the async `requestAuthorization()` call so it
    /// runs with the view's lifetime rather than in an unowned `Task {}` that
    /// SwiftUI may tear down before it reaches the system prompt (#421).
    @State private var authRequestToken = 0

    /// Factory for the notification service, injectable so a test can supply a
    /// mock `NotificationScheduling` and assert the permission request fires.
    var makeNotificationService: () -> NotificationService = { NotificationService() }

    // MARK: Speed options

    /// Speed override options shown in the Picker.
    /// nil = fall back to the global setting.
    private static let speedOptions: [(label: String, value: Double?)] = {
        var options: [(String, Double?)] = [("Use global", nil)]
        let speeds: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
        for s in speeds {
            // Format without trailing zeros: 1.0 → "1", 1.25 → "1.25"
            let formatted = s.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(s))
                : String(s)
            options.append(("\(formatted)×", s))
        }
        return options
    }()

    /// Test-visible accessor for speed options. Only use in tests.
    static var speedOptionsForTesting: [(label: String, value: Double?)] { speedOptions }

    // MARK: Queue age limit options

    private static let queueAgeLimitOptions: [(label: String, value: Int?)] = [
        ("No limit", nil),
        ("1 day", 1),
        ("2 days", 2),
        ("3 days", 3),
        ("5 days", 5),
        ("1 week", 7),
        ("2 weeks", 14),
        ("3 weeks", 21),
        ("30 days", 30),
    ]

    // MARK: Inbox episode count options

    private static let inboxMaxOptions: [(label: String, value: Int?)] = [
        ("No limit", nil),
        ("1 episode", 1),
        ("3 episodes", 3),
        ("5 episodes", 5),
        ("10 episodes", 10),
        ("20 episodes", 20),
    ]

    // MARK: Inbox age limit options (stored as hours in the model)

    private static let inboxAgeLimitOptions: [(label: String, value: Int?)] = [
        ("No limit", nil),
        ("12 hours", 12),
        ("1 day", 24),
        ("2 days", 48),
        ("7 days", 168),
        ("14 days", 336),
    ]

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                playbackSection
                queueSection
                inboxSection
                notificationsSection
            }
            .navigationTitle("Podcast Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityLabel("Done")
                    .accessibilityHint("Closes podcast settings")
                }
            }
        }
    }

    // MARK: Sections

    private var playbackSection: some View {
        Section {
            speedPicker
        } header: {
            Text("Playback")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var queueSection: some View {
        Section {
            Toggle("Add new episodes to queue", isOn: $podcast.autoQueue)
            queueAgeLimitPicker
        } header: {
            Text("Queue")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var inboxSection: some View {
        Section {
            inboxMaxPicker
            inboxAgeLimitPicker
        } header: {
            Text("Inbox")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Notify on new episodes", isOn: notificationEnabledBinding)
                // Request notification permission the first time the user turns
                // this on. The async request is owned by a `.task(id:)` keyed on
                // `authRequestToken` (below) — NOT a bare `Task {}` — so it is
                // guaranteed to run and be awaited with the view's lifetime even
                // though writing a SwiftData @Model property doesn't reliably
                // fire `.onChange` (the model diffs old == new by the time
                // SwiftUI compares) (#421). requestAuthorization() is idempotent:
                // it never re-prompts once the user has decided (#72).
                .task(id: authRequestToken) {
                    guard authRequestToken > 0 else { return }
                    await makeNotificationService().requestAuthorization()
                }
        } header: {
            Text("Notifications")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Sends a notification when new episodes are detected during a background refresh.")
        }
    }

    /// Binding for the "Notify on new episodes" toggle. The `set` performs the
    /// model write AND, when the toggle goes ON, bumps `authRequestToken` so the
    /// `.task(id:)` above runs `requestAuthorization()` with the view's lifetime.
    /// Doing the permission trigger here (rather than via `.onChange` on the
    /// @Model property) is the fix for #421: the toggle now reliably surfaces the
    /// iOS permission prompt the first time it is switched on.
    private var notificationEnabledBinding: Binding<Bool> {
        Binding(
            // `notificationEnabled` is `Bool?` (nil = off, see Podcast / #425);
            // read nil as false so it can drive a `Toggle(isOn:)`.
            get: { podcast.notificationEnabled ?? false },
            set: { isOn in
                let decision = NotificationPermissionTrigger.apply(newValue: isOn)
                podcast.notificationEnabled = decision.persistedValue
                if decision.shouldRequestAuthorization { authRequestToken += 1 }
            }
        )
    }

    // MARK: Pickers

    private var speedPicker: some View {
        Picker("Playback speed", selection: speedOverrideBinding) {
            ForEach(Self.speedOptions, id: \.label) { option in
                Text(option.label)
                    .tag(option.value)
                    .accessibilityLabel(speedAccessibilityLabel(for: option))
            }
        }
        .accessibilityLabel("Playback speed override")
        .accessibilityHint("Sets the playback speed for this podcast. Use global uses the app-wide setting.")
    }

    private var queueAgeLimitPicker: some View {
        Picker("Remove from queue after", selection: queueAgeLimitBinding) {
            ForEach(Self.queueAgeLimitOptions, id: \.label) { option in
                Text(option.label).tag(option.value)
            }
        }
        .accessibilityLabel("Remove from queue after")
        .accessibilityHint("Episodes older than this are automatically removed from the queue")
    }

    private var inboxMaxPicker: some View {
        Picker("Inbox episode limit", selection: inboxMaxBinding) {
            ForEach(Self.inboxMaxOptions, id: \.label) { option in
                Text(option.label).tag(option.value)
            }
        }
        .accessibilityLabel("Inbox episode limit")
        .accessibilityHint("Maximum number of episodes from this podcast in the inbox at one time")
    }

    private var inboxAgeLimitPicker: some View {
        Picker("Remove from inbox after", selection: inboxAgeLimitBinding) {
            ForEach(Self.inboxAgeLimitOptions, id: \.label) { option in
                Text(option.label).tag(option.value)
            }
        }
        .accessibilityLabel("Remove from inbox after")
        .accessibilityHint("Episodes older than this are automatically removed from the inbox")
    }

    // MARK: Bindings

    /// Maps between `Optional<Double>` on the model and the Picker's tag type.
    private var speedOverrideBinding: Binding<Double?> {
        Binding(
            get: { podcast.speedOverride },
            set: { podcast.speedOverride = $0 }
        )
    }

    /// Maps between `Optional<Int>` on the model and the Picker's tag type.
    private var queueAgeLimitBinding: Binding<Int?> {
        Binding(
            get: { podcast.queueAgeLimitDays },
            set: { podcast.queueAgeLimitDays = $0 }
        )
    }

    /// Maps between `Optional<Int>` on the model (inboxMaxEpisodes) and the Picker.
    private var inboxMaxBinding: Binding<Int?> {
        Binding(
            get: { podcast.inboxMaxEpisodes },
            set: { podcast.inboxMaxEpisodes = $0 }
        )
    }

    /// Maps between `Optional<Int>` on the model (inboxAgeLimitHours) and the Picker.
    private var inboxAgeLimitBinding: Binding<Int?> {
        Binding(
            get: { podcast.inboxAgeLimitHours },
            set: { podcast.inboxAgeLimitHours = $0 }
        )
    }

    // MARK: Helpers

    private func speedAccessibilityLabel(for option: (label: String, value: Double?)) -> String {
        guard let value = option.value else { return "Use global speed setting" }
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(value)
        return "\(formatted) times speed"
    }
}
