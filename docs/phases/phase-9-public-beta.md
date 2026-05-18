# Phase 9: Public beta

**Goal:** Earshot is publicly available in TestFlight and Google Play Open Testing with a cap of 1,000 testers. The community knows it exists.

**Estimated duration:** 4-6 weeks (the testing period itself)

## Prerequisites

- Phase 8 complete: private alpha concluded, critical bugs fixed
- App Store Connect app record approved (no App Review needed for TestFlight public link)
- Google Play Console app reviewed and approved for Open Testing
- At least one clean build from the release CI workflow

## Tasks

### 1. Address alpha feedback
- [ ] Triage all issues from private alpha into GitHub Issues
- [ ] Fix all `critical-a11y` labeled issues before public beta
- [ ] Fix all crash-rate issues (target: 99.5%+ crash-free sessions in Sentry)
- [ ] Release build numbers incremented (0.1.x+N)

### 2. App Store Connect metadata (required before public TestFlight)
- [ ] App name: Earshot
- [ ] Subtitle: A podcast player for the way you listen
- [ ] Category: News → Podcasts
- [ ] Description (App Store copy)
- [ ] Keywords
- [ ] Privacy Policy URL: earshot.payown.media/privacy (page must exist)
- [ ] Screenshots: at least iPhone 6.9" and iPhone 6.5" sizes
- [ ] App icon: final 1024×1024 PNG

### 3. Google Play Console metadata
- [ ] Short description (80 chars)
- [ ] Full description
- [ ] Feature graphic (1024×500)
- [ ] Screenshots: phone portrait minimum
- [ ] Content rating questionnaire completed
- [ ] Data Safety form completed

### 4. TestFlight public link
- [ ] In App Store Connect: TestFlight → Public Link → enable
- [ ] Write beta feedback instructions (what to test, how to submit via Settings → Send Feedback)
- [ ] Set TestFlight beta description explaining what Earshot is and who it's for

### 5. Google Play Open Testing
- [ ] In Play Console: Testing → Open Testing → enable
- [ ] Set download cap to 1,000

### 6. Promotion

Priority channels (in order):
1. **BITS email list** — most important; these are the primary users
2. **ACB Community Builder show** — Michael's podcast
3. **Technically Working** — Michael's other podcast
4. **Payown Media website** — payown.media/earshot
5. **Social media** — wherever Michael is active

Announcement copy should lead with:
- Free, open source
- Built for screen reader users from day one
- VoiceOver and TalkBack fully supported
- Quick Actions configurable from the rotor
- No ads, no tracking beyond opt-out crash reports

### 7. Monitor during beta
- [ ] Sentry: watch for new crash types after broader exposure
- [ ] PostHog: watch for features that aren't being used (may indicate UX confusion)
- [ ] GitHub Issues: triage daily during first week, weekly after
- [ ] TestFlight/Play reviews: respond to all reviews during beta
- [ ] Respond to all feedback within 48 hours

### 8. macOS version (optional, parallel track)
- [ ] `flutter create --platforms macos .`
- [ ] Add macOS background audio entitlement
- [ ] Adapt layout for wider screen (sidebar + content split)
- [ ] Submit to Mac App Store alongside iOS if ready before launch

## Definition of done

- TestFlight public link is live and shared
- Google Play Open Testing is live and shared
- Privacy policy page exists at earshot.payown.media/privacy
- Sentry and PostHog are receiving data
- All critical-a11y issues from alpha are resolved
- At least one announcement sent to BITS

## Claude Code prompts for this phase

**Prompt 1: prepare release build**
```
We're preparing the public beta build. Bump the build number in pubspec.yaml,
run flutter test and flutter analyze to confirm clean, then tag the release
so CI produces the artifacts. Tell me the flutter build commands to run locally
to test the release build before tagging.
```

**Prompt 2: fix alpha feedback**
```
Here are the issues from private alpha: [paste GitHub issue list]. Triage each:
critical-a11y, crash, or enhancement. Fix all critical-a11y and crash issues
first. Write a concise summary of what changed for the release notes.
```

**Prompt 3: macOS platform**
```
Add macOS as a Flutter platform to Earshot. Run flutter create --platforms macos .
then check what build errors appear. Fix them. Test that audio playback works
on macOS. Note what UI changes would be needed for a proper Mac experience
without actually making them yet.
```
