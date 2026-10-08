# Changelog

## 0.1.9

- One search box for Open and All Sessions (⌘F): it keeps the same query in both, and in Open it also lists
  matching sessions that aren't open (click to resume). The full-text option searches inside every conversation
- speak mod: `/speak stop` and ■ Stop turn speaking off in every session until `/speak on`, and stop for real
  (it no longer comes back with the next sentence Claude writes)

## 0.1.8

- The built-in status line is one continuous line that wraps onto the next row only when it runs out of width
- Mods load reliably even when your settings.json sets CLAUDE_CODE_PLUGIN_DIRS (passed as --plugin-dir; a mod
  your settings already load isn't loaded twice)

## 0.1.7

- Mods: Claude Code plugins that ship with Tabwise and load into every session it starts. Switch each on or off
  in Settings → Mods (all on by default). First mod: speak, which reads Claude's replies aloud

## 0.1.6

- Sessions that were running when you quit start again at launch, not just the selected one
  (Settings → Sessions → Reopen running sessions at launch)
- The selected session is published to `~/.claude/tabwise/active.json` (sessionId, visibleSessionIds,
  isAppActive, pid, updatedAt) so other tools, like a mod that reads replies aloud, can follow the tab you're on

## 0.1.5

- Show only active sessions (green dot): the ⚡ button at the top of the sidebar, or "Only Active Sessions" in
  the layout menu. Sessions stay visible while working or waiting for you; asleep, exited and shell tabs hide

## 0.1.4

- Continue the last conversation in a folder, like `claude --continue`: a checkbox when picking a folder for a
  new session, File → Continue Last Session in Folder… (⌘O), or paste `claude --continue` into Resume
- Click a Pinned or Archived section title (not just the arrow) to expand or collapse it
- Drafts (unsent prompts) are no longer lost when a tab sleeps, restarts, is archived or closed: they're typed
  back once Claude is ready, retrying until they show up
- Fix "Draft" staying on a renamed session forever (the session name in the input box border hid the box)

## 0.1.3

- Keyboard shortcuts for tab actions, also shown in the right-click menu: ⌘S sleep / wake,
  ⌥⌘S sleep other tabs, ⌘E rename, ⇧⌘N note, ⌥⌘R reveal in Finder, ⌥⌘C copy session ID

## 0.1.2

- ⌘⌫ and ⌥⌫ delete the previous word in the terminal (hold to keep deleting)
- The Pinned sections (open tabs and All Sessions) can be collapsed, and show how many they hold
- Fix leftover lines in Claude Code's slash-command list: the terminal repaints fully once output settles

## 0.1.1

- Fix the app freezing (spinning wheel) while a session with a very large conversation is working:
  transcripts are now read in the background, and a file without a title is searched only once

## 0.1.0

First public release.

- Every Claude Code session as a tab with live status (working / waiting / idle), notifications and a Dock badge
- Sort by most recent message or group by folder (collapsible, with status in the header)
- Pin, rename, color-label, notes, archive, and put tabs to sleep to free memory
- Import running sessions from Terminal; resume any session from a `claude --resume` command
- All Sessions: every past conversation with pins, full-text search and one-click resume
- Tabs, drafts (unsent prompts) and settings survive quitting, crashes and restarts; lazy start for fast launch
- Optional iCloud Drive / folder backup and restore on a new Mac
- Drag-and-drop and ⌘V for images, voice mode, built-in status line, split view, ⌘K switcher, menu bar icon,
  git status, memory use, keep-awake, saved prompts and send-to-several
