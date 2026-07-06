import SwiftUI
import SwiftData
import UIKit

/// Per-podcast settings sheet. Opened from a toolbar button on `EpisodeListView`.
/// All controls bind directly to the `Podcast` SwiftData model — changes persist
/// immediately without a save button.
///
/// Settings without a matching model field (e.g. per-podcast auto-download count)
/// are deferred to a future issue once the data agent adds them to the model.
struct PodcastSettingsView: View {
    @Bindable var podcast: Podcast
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Bumped each time the notification toggle is switched ON. A `.task(id:)`
    /// keyed on this token owns the async `requestAuthorization()` call so it
    /// runs with the view's lifetime rather than in an unowned `Task {}` that
    /// SwiftUI may tear down before it reaches the system prompt (#421).
    @State private var authRequestToken = 0
    /// Whether iOS-level notification authorization is denied. Checked on
    /// appear and again after any authorization request, so a prior denial
    /// (the toggle would otherwise silently do nothing forever) is surfaced
    /// with a path to fix it (#600).
    @State private var isAuthorizationDenied = false

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
                // it never re-prompts once the user has decided (#72). Re-check
                // status afterward so a denial (or a grant) is reflected
                // immediately, without waiting for the sheet to reopen (#600).
                .task(id: authRequestToken) {
                    guard authRequestToken > 0 else { return }
                    await makeNotificationService().requestAuthorization()
                    // Announce only on THIS path (a live toggle flip), not the
                    // silent initial-appear check below — a user who just
                    // switched notifications on and hit a standing denial needs
                    // to hear that it didn't work, since nothing else here tells
                    // them (#600).
                    await refreshAuthorizationStatus(announceIfNewlyDenied: true)
                }
            // Only relevant once the user has actually asked for notifications
            // on this show — a denial is moot noise while the toggle is off.
            if podcast.notificationEnabled == true, isAuthorizationDenied {
                // Icon carries the warning color, text stays at label contrast
                // (never color alone) — matches the app's established
                // icon-carries-color error pattern (AddFeedView, #462) rather
                // than muting the whole row to secondary, which under-signals
                // that this is a real, silent feature failure.
                Label {
                    Text("Notifications are turned off for Earshot. Enable them in Settings to get new episode alerts.")
                } icon: {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.orange)
                }
                Button("Open Settings") { openSystemSettings() }
                    .accessibilityHint("Opens the Settings app to Earshot's notification permissions")
            }
        } header: {
            Text("Notifications")
                .accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Sends a notification when new episodes are detected during a background refresh.")
        }
        // Checked once when the sheet appears, so a denial from a PRIOR session
        // (or a grant made in Settings since the last time this sheet was open)
        // shows up without needing to toggle anything (#600). Silent: this is
        // not a live user action, so nothing to announce.
        .task {
            await refreshAuthorizationStatus()
        }
    }

    /// Re-reads authorization status. `announceIfNewlyDenied` fires a VoiceOver
    /// announcement only on the false→true transition, and only when the
    /// caller is responding to a live toggle flip — never on the silent
    /// initial-appear check, so reopening this sheet never re-announces
    /// already-known state.
    private func refreshAuthorizationStatus(announceIfNewlyDenied: Bool = false) async {
        let wasDenied = isAuthorizationDenied
        let status = await makeNotificationService().currentAuthorizationStatus()
        isAuthorizationDenied = status == .denied
        if announceIfNewlyDenied, isAuthorizationDenied, !wasDenied {
            Announcer.announce(
                "Notifications are off for Earshot in Settings. Enable them there to get alerts for this podcast."
            )
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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

    // Adjustable options reuse the existing curated lists (sentinel first), so a
    // VoiceOver flick steps through them; the visual menu still opens on tap.

    private var speedAdjustableOptions: [AdjustableOptionPicker<Double?>.Option] {
        Self.speedOptions.map {
            .init(value: $0.value, title: $0.label, spoken: speedAccessibilityLabel(for: $0))
        }
    }

    private var queueAgeAdjustableOptions: [AdjustableOptionPicker<Int?>.Option] {
        Self.queueAgeLimitOptions.map { .init(value: $0.value, title: $0.label, spoken: $0.label) }
    }

    private var inboxMaxAdjustableOptions: [AdjustableOptionPicker<Int?>.Option] {
        Self.inboxMaxOptions.map { .init(value: $0.value, title: $0.label, spoken: $0.label) }
    }

    private var inboxAgeAdjustableOptions: [AdjustableOptionPicker<Int?>.Option] {
        Self.inboxAgeLimitOptions.map { .init(value: $0.value, title: $0.label, spoken: $0.label) }
    }

    private var speedPicker: some View {
        AdjustableOptionPicker(
            "Playback speed",
            options: speedAdjustableOptions,
            selection: speedOverrideBinding,
            hint: "Playback speed for this podcast. Use global uses the app-wide setting. Flick up for faster."
        )
    }

    private var queueAgeLimitPicker: some View {
        AdjustableOptionPicker(
            "Remove from queue after",
            options: queueAgeAdjustableOptions,
            selection: queueAgeLimitBinding,
            hint: "Episodes older than this are automatically removed from the queue"
        )
    }

    private var inboxMaxPicker: some View {
        AdjustableOptionPicker(
            "Inbox episode limit",
            options: inboxMaxAdjustableOptions,
            selection: inboxMaxBinding,
            hint: "Maximum number of episodes from this podcast in the inbox at one time"
        )
    }

    private var inboxAgeLimitPicker: some View {
        AdjustableOptionPicker(
            "Remove from inbox after",
            options: inboxAgeAdjustableOptions,
            selection: inboxAgeLimitBinding,
            hint: "Episodes older than this are automatically removed from the inbox"
        )
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
    ///
    /// The setter ALSO writes the value through to the feed-URL-keyed AppSetting
    /// (`podcast_inbox_cap_<feedURL>`) so the cap survives unsubscribe →
    /// re-subscribe, where a fresh `Podcast` is created with a nil cap (#548).
    /// The model field stays the live source of truth for every existing flow.
    ///
    /// This write-through is also the lazy backfill for existing subscribers who
    /// set a cap before the keyed setting existed: their current `Podcast` rows
    /// still hold the cap (which is all any live path reads), and the keyed copy
    /// only matters on a future re-subscribe — so persisting it on their next
    /// edit is sufficient and no launch migration is needed.
    private var inboxMaxBinding: Binding<Int?> {
        Binding(
            get: { podcast.inboxMaxEpisodes },
            set: { newValue in
                podcast.inboxMaxEpisodes = newValue
                AppSettingsStore(context: modelContext)
                    .setPodcastInboxCap(newValue, forFeedURL: podcast.feedURL)
            }
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
