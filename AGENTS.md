# Anakena — instructions for coding agents

Anakena is a local macOS menu bar app (Swift, SwiftPM, no Xcode project) that fixes
wrong-layout typing between a chosen pair of languages. The user wants it installed on THEIR Mac.
There is no prebuilt binary: build from source. Nothing in the repo depends on the
author's machine; the bundle id `com.leo.anakena` is just an identifier, keep it.

## Install on this Mac (do these in order, stop and tell the user if a step fails)

1. Check: `sw_vers -productVersion` (macOS 13+ to run; macOS 14.5+ to build with Xcode 16+), `swift --version` (need >= 6.0). If Swift is missing, `xcode-select --install` may install a suitable toolchain; check `swift --version` again. If Swift is still missing or older than 6.0, ask the user to install Xcode 16+ from the App Store or developer.apple.com.
2. Check the user has keyboard layouts for at least two languages enabled: System Settings → Keyboard → Input Sources. English / Ukrainian is preferred by default; otherwise the first two languages are chosen, preferring English first. Switch the saved pair in the app's "Languages" menu (both need macOS spell-check dictionaries). You cannot add layouts silently; ask the user to add them if missing.
3. `cd` to the repo, run `swift test` (expect 0 failures; optional layout/dictionary tests may skip). NSSpellChecker may be unavailable in a sandbox; report affected tests explicitly.
4. Before running `./scripts/make-cert.sh`, tell the user it creates a self-signed code-signing identity "Anakena Local Signing" in the login keychain, without sudo or trust changes, and ask for permission. A keychain password prompt may appear. On each build, click "Allow" when codesign asks to use the key, never "Always Allow".
5. `./build.sh` — must NOT print the "ad-hoc signing" warning.
6. Install. Do not delete or kill anything without asking the user first.
   - If Anakena is running, quit it: `osascript -e 'quit app "Anakena"'` (macOS may ask the user to allow the terminal to control Anakena), or ask the user to choose `Quit` in its menu. Only if it is still running, ask the user before `pkill -x Anakena`.
   - If `/Applications/Anakena.app` exists, move it to the Trash, do not delete it: `trash /Applications/Anakena.app` (macOS 15+), or ask the user to drag it to the Trash in Finder.
   - `cp -R build/Anakena.app /Applications/ && open /Applications/Anakena.app`
7. Tell the user to grant **Accessibility** (and **Input Monitoring** if needed) to Anakena in System Settings → Privacy & Security. You cannot grant it for them and must not try to bypass TCC. Open the pane for them with `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`.
8. Verify: the menu bar shows the current language code (`EN`/`УК` for English / Ukrainian), and the menu has `✓ Access granted` (or its translation: the menu follows the macOS language). Read it with
   `osascript -e 'tell application "System Events" to tell process "Anakena" to get title of every menu item of menu 1 of menu bar item 1 of menu bar 1'`.
   This check also needs Accessibility permission for the app running it (Terminal/Claude/Codex). If `osascript` fails, ask the user to check the menu bar visually.
9. Functional test (ask the user, keystrokes need their focus): in TextEdit type `ghbdsn` + Space on the EN layout, expect `привіт`.

## Known traps

- Stale permission entry (toggle on, menu says `⚠︎ Grant access…`): remove Anakena from Accessibility / Input Monitoring in System Settings, relaunch, add it again. Do not use `tccutil reset`: it froze a Mac once.
- Secure Event Input stuck (nothing works anywhere): lock/unlock the screen or restart the Mac.
- Always quit Anakena before replacing `/Applications/Anakena.app` (replacing a running copy breaks its signature). Ask before `pkill`; never `rm -rf` the app, move it to the Trash.
- Terminals and IDEs are ignored by default (see `Settings.defaultIgnored`); that is intended.
- Hotkey ⌃⌥Space can clash with the macOS "Select next input source" shortcut.
- Launch at login is toggled from the app menu (SMAppService); it works from /Applications.

## Rules for changing the code

- Keep it fully local: no network code, no logging or persisting of typed text, except learned single lowercased words (Settings alwaysWords/ignoredWords, max 2000 each).
- Do not hardcode paths, usernames, hostnames or certificate hashes.
- `swift test` must stay green; behavior of the detector lives in `Sources/Anakena/Corrector.swift`.
- Languages use primary codes from TIS; the active pair is stored as `langA`/`langB`. Keep pair selection pure and EN/UK behavior compatible. Use Unicode letter checks and layout tables, not script ranges.
- Run the randomized quality harness with `swift test --filter FuzzTests` (requires working EN/UK layouts and spell dictionaries).
- Set `ANAKENA_FUZZ_SEED` (UInt64, default 1) and `ANAKENA_FUZZ_PASSES` (positive Int, default 3) for reproducible runs.
- Reports: `/tmp/anakena-fuzz-report.jsonl` and `/tmp/anakena-fuzz-summary.md`; if blocked, the harness prints its NSTemporaryDirectory fallback.
