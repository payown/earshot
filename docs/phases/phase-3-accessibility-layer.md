# Phase 3: Accessibility layer, Quick Actions, theme system

**Goal:** Every content item exposes user-configurable Quick Actions to VoiceOver and TalkBack, the theme system fully follows system settings including high-contrast, and Reduce Motion is respected everywhere.

**Estimated duration:** 2-3 weeks (part-time)

## Prerequisites

- Phase 2 complete: playback working, now-playing bar, player screen
- `quick_action_configs` table already exists in the database (from Phase 1)

## Tasks

### 1. Quick Actions on episode rows
- [ ] Add `customSemanticsActions` to `EpisodeListTile` mapping to user's configured episode Quick Actions
- [ ] Default episode Quick Actions order: Play now, Add to queue, Mark played/unplayed, Open show notes
- [ ] First action in user's list becomes the `onTap` default
- [ ] Announce action result via `SemanticsService.sendAnnouncement`

### 2. Quick Actions on podcast rows
- [ ] Add `customSemanticsActions` to `PodcastListTile`
- [ ] Default podcast Quick Actions order: Open, Toggle notifications, Toggle auto-queue, Unsubscribe
- [ ] Wire up the actions to the repository

### 3. Quick Action configurator screen
- [ ] Create `lib/features/settings/` feature with a Settings screen
- [ ] Quick Action configurator: reorderable list for each content type (episode, podcast)
- [ ] Persist order changes to `quick_action_configs` drift table
- [ ] Accessible drag-to-reorder with up/down button alternatives for screen readers
- [ ] Link from Settings screen

### 4. High-contrast theme
- [ ] Detect `MediaQuery.of(context).highContrast` (returns true when system high-contrast is on)
- [ ] Wire `AppTheme.highContrastLight()` and `highContrastDark()` through `MaterialApp` — already configured in `main.dart` as `highContrastTheme` and `highContrastDarkTheme`
- [ ] Verify all WCAG AAA contrast ratios (7:1) in high-contrast mode
- [ ] Test on iOS: Settings → Accessibility → Display & Text Size → Increase Contrast

### 5. Reduce Motion
- [ ] Audit every animation in the app
- [ ] Wrap all non-essential animations with `MediaQuery.of(context).disableAnimations` check
- [ ] NowPlayingBar appear/disappear: instant when Reduce Motion is on
- [ ] Page transitions: use fade instead of slide when Reduce Motion is on
- [ ] Player screen open/close: instant when on

### 6. Dynamic Type audit
- [ ] Test every screen at iOS Dynamic Type "Accessibility Extra Extra Extra Large"
- [ ] Fix any clipping, overflow, or cut-off text found
- [ ] Verify `minTileHeight` on list tiles allows rows to grow with larger text
- [ ] Verify player screen controls don't overlap at large sizes

### 7. Settings screen foundation
- [ ] `lib/features/settings/presentation/screens/settings_screen.dart`
- [ ] Linked from subscriptions screen (gear icon in app bar)
- [ ] Sections: Quick Actions, Playback, Privacy, About
- [ ] All settings rows accessible: labeled, tappable, state announced

### 8. Tests
- [ ] Unit tests: Quick Action config read/write from drift
- [ ] Widget tests: `customSemanticsActions` present on episode and podcast tiles
- [ ] Widget tests: Settings screen navigation and section headings accessible

## Definition of done

- VoiceOver actions rotor on an episode row shows at least 4 Quick Actions
- TalkBack custom actions on an episode row shows the same actions
- Quick Action order changes in Settings persist and are reflected immediately in the rotor
- App runs correctly with Increase Contrast enabled (tested on simulator)
- App runs correctly with Reduce Motion enabled — no animations fire
- All screens usable at largest Dynamic Type size without clipping
- All new UI passes `flutter analyze` and tests

## Commands to use during this phase

```bash
# Enable Reduce Motion on iOS simulator
xcrun simctl spawn booted defaults write com.apple.Accessibility ReduceMotionEnabled 1

# Disable
xcrun simctl spawn booted defaults write com.apple.Accessibility ReduceMotionEnabled 0

# Enable Increase Contrast on iOS simulator
xcrun simctl spawn booted defaults write com.apple.Accessibility DarkerSystemColors 1

dart format lib/ test/
flutter analyze
flutter test
```

## Claude Code prompts for this phase

**Prompt 1: Quick Actions on content items**
```
Read docs/phases/phase-3-accessibility-layer.md. Implement customSemanticsActions on EpisodeListTile and PodcastListTile using the user's configured Quick Action order from quick_action_configs. Default order if no config exists: for episodes [Play now, Add to queue, Mark played, Open show notes]. Wire the first action to onTap. Announce action results via SemanticsService.sendAnnouncement. Write widget tests verifying the actions are present in the semantics tree.
```

**Prompt 2: Quick Action configurator**
```
Build the Quick Action configurator in lib/features/settings/. A reorderable list for episode Quick Actions and one for podcast Quick Actions. Each row has up/down buttons as screen-reader-accessible alternatives to drag. Persist changes to quick_action_configs drift table. Link from a Settings screen accessible via a gear icon in the subscriptions screen app bar.
```

**Prompt 3: Reduce Motion and theme audit**
```
Audit all animations in lib/ for Reduce Motion compliance. Wrap non-essential animations with MediaQuery.of(context).disableAnimations. Verify NowPlayingBar, page transitions, and player screen open/close all respect the setting. Test by enabling Reduce Motion on the simulator with: xcrun simctl spawn booted defaults write com.apple.Accessibility ReduceMotionEnabled 1
```

**Prompt 4: Dynamic Type audit**
```
Test every screen at the largest iOS Dynamic Type accessibility size. Fix any clipping, overflow, or truncation. Pay particular attention to the player screen controls, episode list tiles, and the now-playing bar. Document which screens were tested and any fixes made.
```
