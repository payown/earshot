# App Store screenshot capture (#643)

Repeatable, deterministic capture of Earshot's App Store screenshots. Boots the
app straight into each screen through DEBUG-only launch arguments, against an
in-memory store seeded from Michael's real Pinecast feeds, so re-running produces
the same six screens every time.

## Run it

```bash
EarshotSwift/scripts/screenshots/capture.sh
```

Output PNGs land in `scripts/screenshots/output/` (git-ignored). Six files:
`inbox.png`, `queue.png`, `library.png`, `episodeList.png`, `nowPlaying.png`,
`settings.png`.

To reuse a build you already have:

```bash
EARSHOT_APP_PATH=/path/to/Earshot.app EarshotSwift/scripts/screenshots/capture.sh
```

To target a different simulator (must be a 6.9-inch device, and never the
CI-reserved UDID):

```bash
EARSHOT_SCREENSHOT_SIM=<UDID> EarshotSwift/scripts/screenshots/capture.sh
```

## Device / size

Default simulator is an **iPhone 17 Pro Max (6.9-inch)** — the current App Store
Connect reference display class for iPhone. The captured PNGs are already at the
required 6.9-inch resolution; upload them to App Store Connect as-is.

> iPad note: Earshot's target still declares iPad support
> (`TARGETED_DEVICE_FAMILY = "1,2"`), so App Store Connect will also require an
> iPad screenshot set at submission. Tracked on #643. If iPad support is dropped
> for 1.0, that requirement goes away. This script is parameterized by simulator,
> so adding an iPad Pro capture pass is a one-line change once the call is made.

## How it works

Two DEBUG-only launch arguments, handled in
`Earshot/App/Screenshots/ScreenshotHarness.swift`:

| Argument | Effect |
| --- | --- |
| `-uiTestScreenshotSeed` | Replaces the store with a fresh in-memory one seeded from `ScreenshotFixtures`, and skips all network launch work (feed refresh, entitlement sync) so the seed stays exactly as fixtured. |
| `-screenshotScreen <name>` | Boots into one screen: `inbox`, `queue`, `library`, `episodeList`, `nowPlaying`, `settings`. |

The whole harness is wrapped in `#if DEBUG`, so it is **stripped from Release /
TestFlight / App Store builds** and ships nothing.

## What is real vs synthesized

- **Real:** both podcasts (Technically Working, Our Perspective) and every
  episode title, GUID, audio URL, artwork, author, and publish date, pulled from
  the live Pinecast feeds. Artwork renders from the real feed cover URLs.
- **Fixture-set state:** which episodes are played / downloaded / queued /
  in-progress / in the inbox. This makes the screens look lived-in; it is not
  anyone's real listening history.
- **Synthesized (one thing only):** the chapter list on the "Now Playing"
  episode (Technically Working #170). Its show notes carry timestamped chapter
  lines whose titles track that episode's real segments; the app's shipped
  show-notes chapter parser extracts them. The chapter feature is real — only
  this one demo episode's timestamps are authored.

Full provenance is documented at the top of
`Earshot/App/Screenshots/ScreenshotFixtures.swift`.
