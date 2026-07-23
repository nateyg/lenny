# Lenny

A small Mac app that counts down your Claude Code usage, using the bar-floor
scene: the spotlight crawls across the floor and lands on the "Coding Time" line
the moment your usage window turns over.

## Run

```bash
open ~/Lenny/Lenny.xcodeproj   # then ⌘R
```

The built app lands in `build/Build/Products/Debug/Lenny.app` — drag it to
`/Applications` to keep it around.

## How it knows

Two local signals, read out of Claude Code's transcripts. Nothing leaves the Mac
and no hooks are involved — Claude Code has no usage-limit hook to subscribe to.

**The primary source is the desktop app.** Most Claude Code use runs through
Claude Desktop, which writes `~/Library/Application Support/Claude/plan-usage-history.json`
every ~5 minutes — the data behind its "Plan usage limits" panel. Each sample is
`{t, u:{fh, sd}}`, where `fh` is your 5-hour usage as a percentage. Lenny reads
this first (see `DesktopUsage.swift`): `fh` at 100 means locked out, and the
block is reconstructed from where `fh` collapses to zero and activity resumes,
floored to ten minutes. Verified against the app's own panel — within a few
minutes of the displayed reset.

Sources, in priority order: the desktop usage file → an explicit 429 lockout
(names its reset outright) → the CLI transcripts. The last is the weakest, since
it only sees CLI activity and its anchor drifts when you work in Desktop.

**What it still can't see.** The reset time is reconstructed from a percentage,
not read verbatim — the app doesn't store the wall-clock reset anywhere obvious
(`rateLimits` in transcripts is always null; nothing usable is cached under
`~/Library/Caches`), so expect a few minutes of slack. Usage on another machine
also spends the shared budget and leaves nothing here.

**Fallback — the 5-hour block** (`TranscriptReader.swift`) — when neither the
desktop file nor a lockout is available, take the first message of the block,
floor it to **10 minutes**, add 5 hours. Only timestamps are read.

The ten minutes is measured, not guessed. Every lockout message states its own
reset time, so `reset − 5h` is a ground-truth block start; across twelve real
lockouts each one landed exactly on a ten-minute boundary and never on the hour.
Replaying the rule reproduces 10 of 11 resets to the second. Hour-flooring —
what this shipped with first — managed 3 of 17 and ran up to 59 minutes early.

"First message" must include **user** messages. A block begins when you send
something; the assistant's first billable reply lands 2–10 minutes later, often
in the next bucket. Counting only assistant messages drops that to 6 of 11.

**2. An actual lockout** (`LockoutReader.swift`) — when Claude Code refuses a
request it writes an assistant entry with `isApiErrorMessage: true`,
`apiErrorStatus: 429`, and text like:

```
You've hit your session limit · resets 2:30pm (America/Los_Angeles)
```

That states the reset time outright, so it wins over the 5-hour estimate
whenever it's present. The stated time is resolved to the first such wall-clock
moment after the lockout, which handles overnight rollover ("resets 12:40am"
after an 8:47pm lockout means the next day).

## States

The spotlight always crawls right-to-left toward the line; only the stakes
change. Colour carries the difference.

| | Dot & countdown | Meaning |
|---|---|---|
| Free to code | **Green** — "New block in H:MM:SS" | Your 5-hour window rolls over |
| Locked out (429) | **Red** — "Resets in H:MM:SS" | When you can work again |
| No active block | Grey, idle | Starts on your next message |

It moves about half a pixel per minute — you'll never catch it moving, but it's
somewhere new every time you glance over. It's a sundial, not a progress bar.

**Preview Reset** (⌘D, or the menu bar) runs the whole thing in 9 seconds in the
locked-out state — red countdown racing, spotlight crawling to the line, then the
sound and the bounce — then reverts to reality. For demos and screenshots.

**Screensaver** (the button in the status bar, or the menu bar) fills every
display with the scene until any key or a real mouse move. Input is ignored for
the first 0.8s and a move has to exceed 12pt, otherwise the click that launched
it dismisses it instantly. This is *not* a system screen saver — see below.

The Dock icon bounces when you actually get locked out, and again when the limit
lifts. It does *not* bounce on Claude Code's "approaching limit" warning: that
popup is drawn from live API data and never written to disk, so there's nothing
to observe. Predicting it from token burn doesn't work either — across twelve
real lockouts the tokens spent at cutoff ranged 12M to 68M, a 5.5× spread.

Lenny blinks every 7–16 seconds, with the occasional double-blink. The closed
eyelids are a pre-baked `eyelids.png` registered to the artwork rather than
shapes drawn at runtime — the two eyes overlap, so no pair of ellipses covers
their union without leaving a sliver of white.

## The Dock icon

Lenny looks at Claude. On each refresh he reads the Dock's pinned order out of
the `com.apple.dock` preferences domain, finds himself and
`com.anthropic.claudefordesktop`, and swaps his own tile
(`NSApp.applicationIconImage`) to the variant facing the right way.

Caveat: there's no API for the Dock's live tile layout, so this only sees apps
that are **kept** in the Dock. If either app is merely running, it's appended at
the end and won't appear in that list — Lenny falls back to the neutral icon.

## Releasing

`Tools/release.sh` builds Release, signs with Developer ID, packages a DMG,
notarizes and staples it. Two one-time steps only you can do first — create a
**Developer ID Application** certificate (Xcode → Settings → Accounts → Manage
Certificates; an "Apple Development" cert is for local runs and cannot be
notarized), and `xcrun notarytool store-credentials "lenny-notary"` with an
app-specific password. The script checks for the certificate and tells you what's
missing rather than failing halfway.

Notarization is an automated malware scan, not App Review — nothing looks at what
the app is. Skipping it means macOS refuses the download outright and hides the
override in System Settings, which is where a joke app loses its audience.

## The site

`docs/` is a self-contained one-pager, ready for GitHub Pages (Settings → Pages →
main branch, /docs). `Tools/make_site_assets.swift` renders `hero.jpg` from the
app's own art using the same geometry constants, so the shot can't drift from
the real thing — it draws the ⌘D locked-out state, spotlight nearly on the line.
The icon alternates between the two eye directions every 3.2s. The download
button points at
`github.com/nategagnon/lenny/releases/latest` — update that if the repo lands
somewhere else.

## Icons

macOS draws app icons inside a safe area — an 824pt body on a 1024pt canvas —
so full-bleed art looms larger than everything else in the Dock. `Tools/make_icons.swift`
insets Lenny's art to the standard body, adds the drop shadow and the specular
rim (painted through a gradient mask so the highlight has no seam), and
regenerates the `AppIcon.appiconset` from the result. Run it against the Desktop
originals after changing the icon art; never against its own output.

## Seeing the welcome screen again

Menu bar → **Show Welcome Screen**. (It just clears the `hasCompletedSetup`
default, so `defaults write com.nategagnon.Lenny hasCompletedSetup -bool false`
does the same thing from a shell.)

The menu bar shows his eyes (a template image, so it tints like every other
status item); its menu has the countdown, sound toggle, refresh, and quit. Green
button = normal macOS fullscreen. The window is aspect-locked to the artwork so
the scene never crops, and the beam is clipped to the art so it can't spill onto
the letterbox.

## The sound

`homer-woohoo.mp3` is bundled and plays on reset, falling back to the system
`Glass` sound if it's missing. The `NSSound` is held on the model deliberately:
as a local it gets deallocated the moment the function returns, which cuts
playback off or drops it entirely — that's an intermittent-audio bug, not a
file problem.

## A real screen saver

The built-in mode above is a window this app puts up. A *system* screen saver —
one you pick in System Settings — is a separate `.saver` bundle target, signed
and installed on its own.

The catch isn't the drawing, it's the data: on modern macOS these load inside
Apple's sandboxed `legacyScreenSaver` host, so reading `~/.claude/projects`
straight from the saver will most likely be blocked. The way round it is for the
app to publish a tiny state file somewhere both can reach and have the saver read
only that. Worth confirming before committing to the target.

## Files

- `Main.swift` — app, model, setup screen, scene, status bar, menu bar
- `DesktopUsage.swift` — primary source: Claude Desktop's usage percentages
- `TranscriptReader.swift` — fallback 5-hour block derivation from CLI transcripts
- `LockoutReader.swift` — real 429 lockout + stated reset time
- `Lenny_background.png`, `Lenny_beam.png`, `eyelids.png` (blink),
  `lenny_hero.png` (background removed), `eyes_template.png` (menu bar),
  `Lenny_Icon.png` (source for `Assets.xcassets/AppIcon.appiconset`) plus its
  `_left of claude` / `_right of claude` variants
- `Design/` — storyboards, not bundled
- `Tools/` — `make_icons.swift`, `make_hero.swift`, `release.sh`

## Scene geometry

Everything in `enum Art` is a fraction of the artwork, measured off the PNGs
rather than eyeballed, so it holds at any window size:

- the beam is drawn at **1.044×** the art width, matching Storyboard 3
- its bright spot sits at **0.228** across the beam image and **0.902** down
- the spot travels between **x 1.0** (centre on the right edge, so it enters
  half-clipped — 50% more travel than starting fully on screen) and **x 0.52** (resting
  on the line — the chalk line is at x≈0.34 at that height, so this leaves
  "Coding Time" readable with the light touching it)

If the artwork changes, re-measure rather than nudging these by hand — and
regenerate `eyelids.png`, which is derived from the background art by flood-
filling the eye whites (a loose brightness threshold, dilated 1px to swallow the
anti-aliased rim, leaving the drawn black rings intact) and drawing a lid line
across each.
