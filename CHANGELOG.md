# Changelog

## 0.1.26

- "Also answer Yes when a command deletes files" (Settings → Sessions, under Auto-allow) is now off by default: Claude Code asks you before an rm it can't check, unless you turn it on

## 0.1.25

- Schedule a message: right-click a session → Schedule Message… and pick a time (or 15 min, 1 hour, 3 hours, tomorrow 9:00). When it's due it joins the queue, so it waits for a turn in progress; a sleeping session is woken for it. The tab shows the next time; click it to change or cancel
- The queue says why it isn't sending: hover "N queued" to see what it's waiting for (Claude is working, something is typed in the input box, a menu is open…) or why it paused
- Auto-Allowed Commands…: right-click a Claude session to see what Tabwise auto-allowed in it, with times (the last 200)
- Search looks through every message you typed in a session, not only the first and last
- Put idle sessions to sleep (Settings → Sessions; off by default): sessions you haven't messaged in 1–24 hours stop to free memory, and resume when you click them. Never pinned sessions, the one you're on, ones with a reply you haven't seen, or ones with queued or scheduled messages
- What's New: Tabwise → What's New in Tabwise… (also in the Help menu) shows what each version changed. It opens by itself once after an update
- ⌘↩ now stacks messages with images too (shown as "[Image #2]"): Tabwise keeps the image you pasted or dropped and attaches it again when the message is sent. Before, such a message stayed in the box as Send When Done. Images pasted before Tabwise started still stay in the box
- Closing a pinned tab asks first, since it takes the tab out of Pinned, and offers Put to Sleep instead: the session stops and frees memory but stays pinned, and waking it resumes the conversation
- Auto-allow what auto mode blocks now also answers Yes to Claude Code's dangerous-removal questions ("can't be sure it read this command the way the shell will" and "Dangerous rm operation on …"), under the same setting and per-tab switch. These commands delete files: Settings → "Also answer Yes when a command deletes files" turns just this part off
- Search finds sessions you closed, or started, since Tabwise last read your past sessions. Before, a session started after Tabwise opened and then closed couldn't be found by its name until you opened All Sessions
- Sessions whose first message had a large pasted image no longer look empty: they were hidden from search and from All Sessions

## 0.1.24

- Auto-allow what auto mode blocks (Settings → Sessions, on by default): when auto mode's safety check blocks a command, Claude goes on instead of stopping at "Auto mode blocked … Allow it?" (the ask-on-deny mod). Right-click a Claude tab → Auto-allow What Auto Mode Blocks to turn it off or on for that session alone. Switching either one reaches running sessions right away (for sessions started in 0.1.24 or later)
- ⌘↩ now stacks messages that contain pasted text (shown as "[Pasted text #1 +4 lines]"): Tabwise puts the pasted text back into the queued message, empties the box and lets you write the next one. Before, such a message stayed in the box and a second ⌘↩ cancelled it. Images, and text pasted before Tabwise started, still stay in the box until Claude finishes

## 0.1.23

- Send When Done (⌘↩) now stacks messages, for Claude Code, Codex and Antigravity: while the agent works, each ⌘↩ moves the message in the input box into a queue and empties the box for the next one. They are sent one by one, each after the agent finishes the previous one. The tab shows how many are waiting; hover to see them
- Click "N queued" on the tab (or right-click → Edit Queued Messages…) to edit, reorder, remove or add queued messages. Nothing is sent while that window is open. ⌘↩ on an empty input box takes the last one back; right-click → Clear Queued Messages drops them all
- The queue pauses instead of sending when a Claude turn fails or the Mac sleeps mid-reply, after a restart, and when the input box shows anything other than the message about to go out (so two messages can't go out merged as one). ⌘↩ on an empty box resumes it

## 0.1.22

- Click a session ID shown in a terminal (for example in `claude --resume <id>`, `codex resume <id>` or `agy --conversation <id>`) to resume that session in its own folder, or to switch to its tab when it's already open. Works for Claude Code, Codex and Antigravity; the pointer turns into a hand over IDs Tabwise knows

## 0.1.21

- Model router (off by default; turn it on in Settings → Model Router, or choose Automatic in a session's Model or Effort menu): Tabwise judges each message you send and puts the job on the model that fits it — a light model for questions and chores, your everyday model for normal work, the strongest one for design and hard bugs. It works for Claude, Codex and Antigravity; you choose the model and effort for each level, and automatic model and automatic effort can be turned on separately
- Each session can have its own model and effort: right-click it → Model or Effort. Set them by hand for one session and leave the others automatic; this works with the router off too. You can also write "use Fable" or "use a cheaper model" in a message
- Codex and Antigravity: restarting a tab after "/new" or "/clear" no longer brings back the conversation from before it

## 0.1.20

- Right-click a folder in Finder for "New Tabwise Session Here" or "Continue Tabwise Session Here" (under Quick Actions or Services)

## 0.1.19

- 0.1.18's download contained an older build by mistake, so what it listed didn't arrive. This version really has it:
  - Links and file paths in a session underline when you hover them and open with a plain click
  - Every folder gets its own color: up to 240 distinct colors instead of 12 that repeated
  - All Sessions can group conversations by folder: the folder button by the search box, or Order in the filter menu
  - The color dots in the Color and Folder Color menus show their colors

## 0.1.18

- Links and file paths in a session underline when you hover them and open with a plain click (no more copy and
  paste; ⌘ no longer needed)
- Every folder gets its own color: up to 240 distinct colors instead of 12 that repeated
- All Sessions can group conversations by folder: the folder button by the search box, or Order in the filter menu
- The color dots in the Color and Folder Color menus show their colors again (newer macOS drew them all white)

## 0.1.17

- sudo-box: the password box now says what the command will do, in a sentence or two from Claude, above the
  command itself, so you know what you're allowing before you type your password

## 0.1.16

- New mod, sudo-box: Claude runs commands that need sudo itself instead of asking you to paste them into a
  terminal. A macOS password box shows the exact command; type your password and click Allow, and the output goes
  straight back to Claude (Cancel stops it; nothing is stored). Settings → Mods turns it off

## 0.1.15

- Opening a sleeping tab or reopening a closed one counts as using it: it goes to the top, like a message does
- When tabs are in your dragged order, a blue ↑↓ button at the top of the sidebar sorts them by last used again
  (the order choice is now called "Last Used First")

## 0.1.14

- Drag tabs into any order in the sidebar (the list, a folder group or Pinned). Your first drag switches to manual
  order and they stay where you put them; sidebar menu or View → Last Message First switches back
- Sleeping sessions move to their own compact "Asleep" section at the bottom: one dimmed line with a moon each.
  Opening one wakes it and it goes back to its place
- Codex and Antigravity tabs get the MCP servers Claude Code has for their folder (claude mcp add, and an approved
  .mcp.json). Codex gets them at launch without touching its config; Antigravity's mcp_config.json gets them, and
  Tabwise removes only the ones it added. claude.ai connectors (Gmail, Drive…) stay Claude-only. Settings → Share
  Claude's MCP servers turns it off

## 0.1.13

- Codex (OpenAI) and Antigravity (Google) tabs next to Claude: pick the agent in New Session (⌘T), or right-click a
  tab → Start New Session With. They show working / needs-you / done like Claude tabs (with notifications), and
  resume their conversation after a restart, sleep or quit. A small Codex / Antigravity label marks them in the sidebar.
  Claude-only features (drafts, Send When Done, status line, mods, All Sessions history) stay Claude-only for now
- Search matches every word you type anywhere in a session (name, folder, messages, note, agent), and treats
  "-", "_", "." and "/" as spaces: "claude code" finds sessions in …/claude-code, "codex" finds Codex tabs

## 0.1.12

- Send When Done no longer sends your draft when Claude was cut off instead of finishing: closing the lid
  (the Mac going to sleep), an API error or an interruption keep the draft unsent

## 0.1.11

- Send When Done (⌘↩): finish writing your next message while Claude works, press ⌘↩, and Tabwise sends it
  as soon as Claude finishes (never while it asks you something). The tab shows "Sends when done"; ⌘↩ again
  cancels. Also in the tab's right-click menu and File menu
- Settings → Saved prompts: Add works when your input method is still holding typed text, Return adds too, and
  Add with an empty box puts the cursor there

## 0.1.10

- No more freezes when Dropbox, iCloud Drive or another cloud folder stalls: reading mods, checking that a
  session's folder exists and checking the backup now give up after a moment instead of hanging the app

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
