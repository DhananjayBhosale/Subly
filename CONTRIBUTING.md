# Contributing to Subly

Thanks for looking. This file says what you need, how the code is laid out, and what
to run before you open a pull request.

## Requirements

- macOS 26 or later
- Xcode 27 or later (Swift 6.4 toolchain)
- An Apple Silicon Mac

Subly cannot be built or run on Intel Macs, older macOS, Linux, or Windows. It uses
the Speech, Translation, and FoundationModels frameworks from the macOS 26 SDK, and
`Package.swift` sets the minimum platform to macOS 26. There is no fallback path.

The one exception is the `SublyCaptions` target, which uses only Foundation. CI cannot
build Subly, so it only checks that this stays true, among other static checks (see
`.github/workflows/ci.yml`). Build and test on your Mac.

## Build and test

```bash
swift build                    # debug build of every target
swift test                     # all unit tests
./Scripts/build_app.sh         # release build, assembles build/Subly.app, ad-hoc signs it
./Scripts/build_engine.sh      # rebuilds the bundled whisper.cpp runtime
```

`Resources/engine/` is gitignored. A fresh clone has no `whisper-cli` until you run
`./Scripts/build_engine.sh`. It needs `cmake` and the Xcode command line tools, clones
whisper.cpp into `vendor/` (also ignored), and checks out the version pinned in the
script. Without it the app still works with Apple's engines. The optional Whisper and
Apex models will not run.

`swift test` currently runs 235 tests: 152 in `SublyCaptionsTests` and 83 in
`SublyEngineTests`.

`./Scripts/run.sh` builds and opens the app.

## Architecture

| Target | What it is |
|---|---|
| `SublyCaptions` | Pure, deterministic caption core. Foundation only. Timing spine, segmentation, caption rules, romanization, SRT/VTT/TXT/JSON writers, project format. Almost all tests live here. |
| `SublyEngine` | Speech, translation, and model routing. Apple Speech and Translation, FoundationModels, AVFoundation, the capability registry, locale reservations, and the downloadable Whisper/Apex models run through whisper.cpp. Also `AppUpdate`, the rules for trusting an update (signature, versions, checksum), which have no UI and are unit-tested. |
| `SublyTranslate` | A small bridge to a SwiftUI-attached `TranslationSession`. Built in Swift 5 language mode on purpose, because `translationTask` hands over a non-Sendable session that Swift 6 strict concurrency rejects. |
| `SublyApp` | The SwiftUI app. |

`subly-cli` and `subly-bench` are small command line harnesses. `subly-cli` runs the
same pipeline as the app, except translation, which macOS only provisions through a UI
session.

`SublyCaptions` has no Apple-framework dependencies on purpose. That is what makes it
deterministic and testable: no model, no OS state, no network. Keep it that way. Do not
add an import of anything but Foundation.

No test target depends on `SublyApp`. An executable target with a UI cannot be
imported by tests the usual way, so UI and `AppModel` logic are verified by headless
harnesses built into the app instead (next section).

If you add logic to `AppModel`, prefer extracting the pure part into `SublyCaptions` so
it can have a real unit test. `Sources/SublyCaptions/CueTiming.swift` is the worked
example. It started inside `AppModel`, where no test could reach it, so the rule that
stops captions overlapping had no coverage.

## Headless harnesses

The app reads environment variables at launch (`AppDelegate.applicationDidFinishLaunching`
in `Sources/SublyApp/SublyApp.swift`). They exist so the app can be checked with the
screen locked or over SSH. Run the built app directly:

```bash
SUBLY_SELFCHECK=1 ./build/Subly.app/Contents/MacOS/Subly
```

Results are written to stderr with a prefix (`GEN:`, `ENGINE:`, `STORAGE:`, `OUT:`,
`OVERLAY:`, `PROBE`). Most checks quit the app when done.

| Variable | Value format | What it does |
|---|---|---|
| `SUBLY_SELFCHECK` | any value | Reports window count, titles, frames, and activation policy, then exits. Tells "no window" from "window cannot be listed". |
| `SUBLY_LAYOUT_CHECK` | any value | Resizes the real window through a set of widths and reports the layout mode and responsive flags at each. Loads the newest saved project first (unless the route is `empty`), so the editor is actually built. |
| `SUBLY_LAYOUT_SHOTS` | output directory | With the layout check, writes a PNG per route per width, the Look panel a screenful at a time (`look-1`, `look-2`…), and a contact sheet of every caption look on a dark and a bright picture (`looks-dark`, `looks-bright`). Layout only: it does not composite system materials, so bars and panels can look white in Dark Mode. |
| `SUBLY_LAYOUT_ROUTE` | `empty`, `home`, `new`, or `editor` (default `editor`) | Which step the layout check sweeps. `empty` skips loading a project. |
| `SUBLY_EDIT_CHECK` | `file\|lang\|outputs` | Runs real generation, then asserts the editing rules: identical cue counts and timings across tracks, edit isolation, undo, reflow, and export. |
| `SUBLY_SPELLING_CHECK` | `file\|lang\|outputs\|heard\|preferred` | Makes captions, changes one word as a person would, and checks the spelling is learned, offered for the rest of the track, and used when the captions are made again. Learning is never saved in a test run. With `SUBLY_SPELLING_UNDO`, checks that Undo un-teaches it instead; `SUBLY_SPELLING_PAUSE` (seconds) holds the banner for a screenshot. |
| `SUBLY_OVERLAY_EDIT_CHECK` | `file\|lang\|outputs` | Edits a caption the way clicking it on the video does, and confirms the new words reach the export. |
| `SUBLY_GENERATE` | `file\|lang\|outputs\|target[\|names]` | End-to-end generation, including translation (which needs a UI-attached session). `target` defaults to `en`; `names` is a comma-separated list for "Names and brands". Example: `fixtures/hi_video.mp4\|hi-IN\|original,romanized\|en`. |
| `SUBLY_ENGINE_CHECK` | language code, for example `hi-IN` | Lists the engine menu for that language and selects each entry, checking it reads back. Restores the previous choice. |
| `SUBLY_STORAGE_CHECK` | any value | Prints the storage breakdown the Settings tab shows, so the figures can be compared with the filesystem. |
| `SUBLY_APPEARANCE` | `light` or `dark` | Forces the app appearance, so Dark Mode can be checked without changing system settings. |
| `SUBLY_OPEN_RECENT` | `1`, `home`, `new`, or `languages` | Opens the newest saved project into the editor (`1`), the projects step (`home`), the Choose step (`new`), or the speech models sheet (`languages`), without re-running speech recognition. |
| `SUBLY_OPEN_PROJECT` | project name (case-insensitive substring) | With `SUBLY_OPEN_RECENT`, opens that saved project instead of the newest. |
| `SUBLY_WINDOW_SIZE` | `WIDTHxHEIGHT`, for example `900x600` | Sets the window content size on launch, for capture with real window-server screenshots. |
| `SUBLY_PROBE_TIMING` | any value | Times the capability probe cold and warm, and `systemState`. Prints a `PROBE` line. |
| `SUBLY_PREVIEW_LANGUAGE` | language tag, for example `mr` | With `SUBLY_OPEN_RECENT`, shows the opened project as if it were in that language. Not saved. |
| `SUBLY_AUTOPLAY` | any value | With `SUBLY_OPEN_RECENT`, starts playback, for measuring CPU while playing. |
| `SUBLY_RECUT_CHECK` | project name | Changes words per caption, times the re-cut, undoes it and restores the original setting. Prints `RECUT` lines. |
| `SUBLY_REDO_CHECK` | any value | With `SUBLY_GENERATE`, plays from the middle, presses Listen Again, and reports where the playhead went and what the redo covered. |
| `SUBLY_GENERATE_ALL_CUES` | any value | With `SUBLY_GENERATE`, prints every caption, not the first four. |
| `SUBLY_PROJECTS_DIR` | folder path | Reads and writes projects there instead of `~/Library/Application Support/Subly/Projects`. Use it for any check that deletes. |
| `SUBLY_DELETE_CHECK` | count (default 2) | With `SUBLY_PROJECTS_DIR`, opens the newest project, deletes the newest N at once, and checks the list, the folders and the open project. Prints `DELETE` lines. Deleted projects go to that volume's Trash. |
| `SUBLY_CAPTION_EDIT_CHECK` | project name | Splits a caption, merges it, undoes both, and checks every track still shares one set of timings. Prints `EDIT` lines. Use a test project: it saves. |
| `SUBLY_DETECT_CHECK` | media file path | Imports the file and runs language detection. Prints a `DETECT` line. Saves nothing. |
| `SUBLY_KEY_CHECK` | any value | Focuses a text field and sends Space, ← and "c" through the app, checking they edit the text instead of starting playback. Prints `KEY` lines. |
| `SUBLY_VIDEO_EXPORT_CHECK` | output `.mp4` path | With `SUBLY_OPEN_RECENT`, exports the project as a video with burned-in captions, without a save panel. Prints `VIDEO` lines, including whether the bundled Instrument Serif font registered. |
| `SUBLY_PREVIEW_TEMPLATE` | a look's name in code, for example `clean`, `boldPop`, `karaoke`, `neon`, `wordBox`, `oneWord` or `rainbow` (see `CaptionStyle.Template`) | With `SUBLY_OPEN_RECENT`, shows the project in that caption style. Not saved. |
| `SUBLY_SHOW_LIST_LATER` | any value | With `SUBLY_OPEN_RECENT`, switches the editor to the caption list a moment after it opens. |
| `SUBLY_HOME_DURING_RUN` | any value | With `SUBLY_GENERATE`, goes back to the projects step while captions are being made, and reports the step after the run. |
| `SUBLY_PANEL_TAB` | `captions`, `look` or `share` | With `SUBLY_OPEN_RECENT`, opens that tab of the editor panel. |
| `SUBLY_SEEK` | seconds | With `SUBLY_OPEN_RECENT` or `SUBLY_LAYOUT_CHECK`, moves the playhead there, for capturing a caption on screen. |
| `SUBLY_UPDATE_FEED` | URL of an `update.json` (a `file://` URL works) | Points the update check at that file instead of GitHub; its signature must sit beside it with `.sig` added. Allows `file://` download links. It never changes the public key an update must be signed with. |
| `SUBLY_UPDATE_CHECK` | `check`, `install`, `window` or `report` | `check` looks, prints `UPDATE result …` and quits. `install` looks, then downloads, verifies and replaces this copy without asking, printing an `UPDATE …` line per step; it restarts the new binary directly with `report`, so no normal session starts. `window` looks and leaves the Software Update window open. `report` is what the restarted copy does: append `UPDATE relaunched <version>` to `SUBLY_UPDATE_LOG` and quit. Run it on a scratch copy of the app, never on the one in Applications. |
| `SUBLY_UPDATE_LOG` | file path | With `SUBLY_UPDATE_CHECK`, also appends every `UPDATE` line there, so the restarted copy's line lands next to the old one's. |
| `SUBLY_UPDATE_SAVE_DIR` | folder path | With `SUBLY_UPDATE_CHECK=install`, where the verified disk image goes when Subly cannot replace itself. A test run otherwise saves nothing, to keep off the real Downloads folder (macOS asks permission for it). |
| `SUBLY_MENU_CHECK` | any value | Prints every menu with its shortcut and whether it is enabled, and presses ⌘E to prove the command is live. |
| `SUBLY_PREPARE_TIMEOUT` | seconds | Read in `SublyTranslate`, not the app delegate. Shortens the wait for Apple's translation download sheet from 600 s, for runs where nobody is there to accept it. |

There is also `SUBLY_OUTPUT_CHECK` (`file|wrongLang|wantedOutput`), which opens a
project with a wrong spoken language and asks for another output. It is not part of
the matrix below but follows the same pattern.

## Releasing a version

Subly updates itself from GitHub Releases. A copy of Subly trusts an update only if
`update.json` carries our Ed25519 signature (the public key is `AppUpdate.publicKey`),
because the app is ad-hoc signed and macOS cannot say who made a download.

1. Raise `VERSION` in `Scripts/build_app.sh` and the version in `README.md`,
   `site/index.html` and `docs/KNOWN_LIMITS.md`. Write the release notes, and a few
   bullet lines for the update window.
2. `swift test`, then `./Scripts/make_dmg.sh`. It writes `build/Subly-<version>.dmg`.
3. Copy it to `build/Subly.dmg`. The asset must be named `Subly.dmg`: the website and
   the signed update link use that name.
4. `./Scripts/sign_update.sh build/Subly.dmg <update notes file>` writes
   `build/update.json`, `build/update.json.sig` and `build/SHA256SUMS.txt`, then
   checks the signature with the app's own code. The private key stays in the login
   Keychain as "Subly update signing key" and is read only through a pipe; it is
   never printed, written to a file or passed as an argument.
5. Create the GitHub release and upload all four files: `Subly.dmg`, `update.json`,
   `update.json.sig` and `SHA256SUMS.txt`. GitHub's `releases/latest/download/…` links
   point at the newest release that is not a pre-release, so publish a draft or
   pre-release first if you want to try one.

To rehearse an update, point a scratch copy of the app at a signed feed with
`SUBLY_UPDATE_FEED` (see above). Do not run it on `/Applications/Subly.app`.

If the key is lost, installed copies cannot be updated from inside the app. People
would have to download the next release by hand once, and the new copy would carry a
new public key. Copies older than 1.4 have no updater, so they download 1.4 by hand.

## Before you open a pull request

Run, on macOS 26 on Apple Silicon:

0. `./Scripts/make_fixtures.sh` once, to make the test clips in `fixtures/` with your
   Mac's own voices. They are not in git: recordings of Apple's system voices can't be
   shared publicly.
1. `swift test`
2. `./Scripts/full_sweep.sh`. It runs 11 language cases end to end and writes
   `build/sweep/report.txt`.
3. `./Scripts/test_real_videos.sh`, if you touched timing, segmentation, or the engine.
4. For UI changes, the layout and crash matrix: run `SUBLY_LAYOUT_CHECK` in both
   `SUBLY_APPEARANCE=light` and `dark`, across the routes `empty`, `home`, `new` and
   `editor`. Look at the app, not only the harness output.

One practical note. `test_real_videos.sh` runs on a folder of your own videos, which
are never added to the repository. Say in your pull request which checks you could run.

Speech recognition is not deterministic. Do not write a test that asserts an exact cue
count or text from real footage.

## Code style

- Comments explain why, and often record the bug that motivated the code. Look at
  `CueTiming.swift` and `build_app.sh` for the tone. Do not add comments that restate
  the line below them.
- The UI is plain. No gradients, no tinted cards or row washes. Chrome is neutral and
  colour is spent on meaning.
- All colours go through `Palette` and `TrackPalette` in
  `Sources/SublyApp/DesignSystem.swift`. Each is a light/dark pair that clears 4.5:1
  contrast against its own appearance's window background (`#ECECEC` light, `#1E1E1E`
  dark). Do not hardcode a colour in a view.
- Keep `SublyCaptions` Foundation-only (see above).
- Prefer the smallest change that fixes the problem. Do not add a dependency without a
  concrete need.

## Media in issues and tests

Do not commit or attach copyrighted media, recordings of real people, or recordings of
Apple's system voices. `fixtures/` is made on your Mac by `Scripts/make_fixtures.sh` and
is ignored by git.
