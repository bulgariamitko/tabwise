# Tabwise

**All your Claude Code sessions in one window.** Tabwise is a native macOS terminal built for people who run
many [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) sessions at once: every session is a tab
in a sidebar with live status, and nothing is lost when you quit, restart, or move to a new Mac.

**[Download the latest version](https://github.com/bulgariamitko/tabwise/releases/latest)** · macOS 14 or later · Apple Silicon and Intel

![Tabwise: sessions in a sidebar with live status, folder colors, git branches and drafts](docs/screenshot.png)

## Features

**Sessions**
- Every Claude Code session is a tab: **working**, **waiting for you**, or **idle**, with notifications and a Dock badge when one finishes or needs input. <kbd>⌘J</kbd> jumps to the one that has waited longest.
- Sorted by the session you last messaged, or **grouped by folder** in collapsible groups that still show what's working inside.
- Pin, rename, color-label, add notes, archive, or **put a tab to sleep** to free its memory (it resumes where it was when you open it).
- **Import** the sessions you already have running in Terminal, or **resume** any session by pasting `claude --resume <id>` (flags are kept).
- **Split view**, <kbd>⌘K</kbd> quick switcher, menu bar icon with live counts.
- **Queue messages while the agent works** (Claude Code, Codex, Antigravity): type a message and press <kbd>⌘↩</kbd>, and it waits for the current turn to finish instead of cutting in. Press it again for each new message to stack as many as you like; they go out one by one, each after the previous reply. Click "N queued" on the tab to edit, reorder or remove them before they're sent.

**Model router** (off by default; Settings → Model Router)
- Tabwise reads the message you send and **puts the job on the model that fits it**: a light model for questions and chores, your everyday model for normal work, the strongest one for design, hard bugs and big changes. It works the same way for Claude Code, Codex and Antigravity, and you choose the model and effort for each level.
- It switches **only when that pays off**: at a conversation's first message, up when the work clearly gets harder, and down while the conversation is still short or after an hour's pause. A switch makes the agent re-read the whole conversation at full price, so changing models on every message would cost more, not less.
- **Each session can have its own model and effort**: right-click it → Model or Effort to set them by hand for that session, and leave the others automatic. This works with the router off too. Or just write "use Fable" or "use a cheaper model" in a message.

**History**
- **All Sessions** lists every past conversation on your Mac with its title, folder and last message — with pins, full-text search (Latin and Cyrillic), and one-click resume.
- **Click a session ID to resume it**: when a terminal shows a Claude Code, Codex or Antigravity session ID (say, in a `claude --resume <id>` line), click it to open that session in a tab, in its own folder, or to switch to its tab if it's already open.

**Never lose work**
- Tabs and their order, names, pins, notes and colors are restored after quitting or restarting; background tabs start only when you open them, so launch is fast.
- **Unsent prompts are saved**: text typed into Claude's input box but not sent yet survives a crash or restart.
- Optional **iCloud Drive backup** (or any folder, e.g. Dropbox) of Tabwise's data and your conversations; a new Mac restores everything on first launch.

**Terminal**
- Drop files or images onto a session to attach them; <kbd>⌘V</kbd> pastes clipboard images into Claude.
- Claude Code's voice mode works (hold Space to talk).
- Built-in [status line](https://github.com/bulgariamitko/claude-code-statusline): model, effort, rate limits, tokens, git and session time.
- Git branch and uncommitted changes, memory use per session, keep-Mac-awake while sessions work, saved prompts (<kbd>⌃⌘1</kbd>…<kbd>⌃⌘9</kbd>) and sending one prompt to several sessions.

## Install

1. Download `Tabwise-<version>.dmg` from [Releases](https://github.com/bulgariamitko/tabwise/releases/latest), open it and drag Tabwise to Applications.
2. Install Claude Code if you haven't: `curl -fsSL https://claude.ai/install.sh | bash`
3. Open Tabwise. It checks for Claude Code and offers to import the sessions you already have running.

Tabwise updates itself (Tabwise → Check for Updates…).

## Build from source

Requires Xcode 16 or later.

```sh
git clone https://github.com/bulgariamitko/tabwise.git
cd tabwise
./build.sh install      # builds build.noindex/Tabwise.app and copies it to /Applications
```

`./release.sh` builds a signed, notarized universal `.dmg` plus the Sparkle `appcast.xml` (needs a Developer ID certificate and notarization credentials — see the top of the script).

## Privacy

Tabwise runs entirely on your Mac. It reads Claude Code's own files in `~/.claude` to show session status and history, never sends your data anywhere, and has no analytics. The only network requests it makes are update checks against this repository's releases, and — only if you turn it on — the backup to your own iCloud Drive or folder.

## Credits

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza (MIT) — terminal emulation
- [Sparkle](https://sparkle-project.org) (MIT) — updates
- [claude-code-statusline](https://github.com/bulgariamitko/claude-code-statusline) (MIT) — the built-in status line

## License

[MIT](LICENSE) © 2026 Dimitar Klaturov

Tabwise is an independent project and is not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.
