import SwiftUI

/// Full speed-picker sheet, presented from the Now Playing screen's speed badge.
///
/// Layout:
/// - Quick-tap grid of common speeds.
/// - A stepper for precise 0.1x adjustments across the full 0.5x-5.0x range.
/// - A segmented scope: "This podcast" vs "Global". Changing the scope writes
///   or clears `Podcast.speedOverride` accordingly.
///
/// The selected speed applies immediately via `PlayerService`. Designed so VoiceOver
/// users can both swipe through the grid and use the stepper without extra layers.
struct SpeedPickerSheet: View {
    @Environment(PlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// Whether the user intends to set a per-podcast override (true) or change
    /// the global speed (false). Starts whichever reflects the current state.
    @State private var podcastScope: Bool

    /// The speed value shown in the stepper. Seeded from the current effective
    /// rate on appear.
    @State private var stepperSpeed: Double

    init() {
        // Defer until body runs; the @State initial values come from the player,
        // but @Environment isn't available in init(). Use placeholders here and
        // seed properly in .task {}.
        _podcastScope = State(initialValue: false)
        _stepperSpeed = State(initialValue: 1.0)
    }

    var body: some View {
        NavigationStack {
            List {
                scopeSection
                shortcutsSection
                stepperSection
                if podcastScope {
                    resetSection
                }
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Seed state from the live player once the environment is available.
                stepperSpeed = player.effectiveRate
                podcastScope = player.hasPodcastSpeedOverride
            }
            .onChange(of: podcastScope) { _, newScope in
                let msg = newScope
                    ? "Scope set to this podcast."
                    : "Scope set to all podcasts."
                Announcer.announce(msg)
            }
        }
    }

    // MARK: Scope toggle

    private var scopeSection: some View {
        Section {
            Picker("Apply speed to", selection: $podcastScope) {
                Text("This podcast").tag(true)
                Text("All podcasts").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Apply speed to")
        } header: {
            Text("Scope")
        } footer: {
            Text(podcastScope
                ? "Saves a speed override for this podcast only."
                : "Updates the global default. Clears any podcast-specific override.")
        }
    }

    // MARK: Quick shortcuts

    @ViewBuilder
    private var shortcutsSection: some View {
        Section("Quick speeds") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: Spacing.sm)], spacing: Spacing.sm) {
                ForEach(PlaybackLogic.speedShortcuts, id: \.self) { speed in
                    let isSelected = PlaybackLogic.clampedSpeed(stepperSpeed) == speed
                    Button {
                        applySpeed(speed)
                    } label: {
                        Text("\(speed, specifier: "%g")x")
                            .font(.callout.monospacedDigit())
                            .fontWeight(isSelected ? .bold : .regular)
                            .foregroundStyle(isSelected ? .white : .primary)
                            .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
                            .contentShape(Rectangle())
                            .padding(.vertical, Spacing.sm)
                            .background(
                                isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PlaybackLogic.spokenRate(speed))
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityHint("Sets speed")
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    // MARK: Stepper (full range)

    private var stepperSection: some View {
        Section("Precise speed") {
            HStack {
                Text("Speed")
                Spacer()
                Text("\(stepperSpeed, specifier: "%g")x")
                    .font(.body.monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            // Stepper for VoiceOver increment/decrement and sighted +/- tapping.
            Stepper(
                value: $stepperSpeed,
                in: PlaybackLogic.minSpeed...PlaybackLogic.maxSpeed,
                step: PlaybackLogic.speedStep
            ) {
                EmptyView()
            }
            .onChange(of: stepperSpeed) { _, newValue in
                let clamped = PlaybackLogic.clampedSpeed(newValue)
                stepperSpeed = clamped
                applySpeed(clamped)
            }
            .accessibilityLabel("Speed stepper")
            .accessibilityValue(PlaybackLogic.spokenRate(stepperSpeed))
            .accessibilityHint("Swipe up or down to adjust in 0.1x steps")
        }
    }

    // MARK: Reset to global

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                podcastScope = false
                player.clearPodcastSpeedOverride()
                stepperSpeed = player.effectiveRate
            } label: {
                Label("Reset to global speed", systemImage: "arrow.counterclockwise")
            }
            .accessibilityLabel("Reset to global speed")
            .accessibilityHint("Removes the speed override for this podcast")
        }
    }

    // MARK: Helpers

    private func applySpeed(_ speed: Double) {
        let clamped = PlaybackLogic.clampedSpeed(speed)
        stepperSpeed = clamped
        if podcastScope {
            player.setPodcastSpeedOverride(clamped)
        } else {
            player.setGlobalSpeed(clamped)
        }
    }
}
