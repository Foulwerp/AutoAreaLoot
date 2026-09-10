# AutoAreaLoot

AutoAreaLoot automatically loots nearby corpses when it is safe to do so.

## Behavior

- Loots nearby corpses when an NPC death event fires
- Ignores Nampower death events whose units are clearly beyond loot range
- Individually configurable death and movement-stop triggers
- Optional in-combat looting, enabled by default
- Coalesces blocked triggers into one pending loot pass
- Runs one final pass after combat when a combat-time trigger occurred
- Avoids interrupting manual loot windows
- Preserves new death requests received during an active loot walk
- Coalesces same-area movement stops into the active walk, while preserving one
  follow-up after moving into a new loot area even if the active walk succeeds
- Limits same-area movement-stop scans to one every 0.5 seconds, but permits an
  immediate scan after moving at least five yards into a new loot area
- Waits 0.15 seconds after movement stops and cancels the attempt if movement
  resumes; death requests received while moving remain queued for that stop
- Detects actual player speed so RMB strafing, jumping, and other displacement
  are not dependent on forward/back movement events
- Uses a bounded latency-adjusted settling period after successful walks,
  avoiding rescans while loot is still being delivered
- `/aal` opens a small settings panel with enable, death, movement-stop, and combat toggles
- `/aal log` opens a compact, scrollable session loot log
- `/aal debug` opens a bounded, copyable diagnostic trace without flooding chat
- Confirms item loot from the player's localized loot messages and filters it against the corpse scan
- Uses corpse GUIDs to prevent repeated scans from creating duplicate live
  loot-confirmation expectations
- Shows money totals and optionally combines matching item rows
- Shows the newest 500 loot events first with timestamps when rows are uncombined
- Keeps timestamps aligned in a fixed column and shows item tooltips on hover
- Keeps full-session combined item totals and money totals independently of
  the recent-event display limit
- Reuses only the visible loot-log rows and defers redraws while the log is closed
- Supports resizing the loot log down to a compact minimum size
- Remembers the loot log's size and screen position
- Can optionally open the loot log automatically on login or `/reload`
- Automatically uses a built-in pfUI theme when pfUI is loaded
- Slash commands can still enable, disable, or report the addon status

## API requirement

AutoAreaLoot requires the `C_Loot.LootAllCorpses` function provided by the ClassicAPI DLL. It checks for that function at runtime and displays a chat message if it is unavailable.

Nampower is optional. When its `UNIT_DIED` event is available, the addon uses it; otherwise it falls back to `CHAT_MSG_COMBAT_HOSTILE_DEATH`.

## Installation

Use the Twow/Octowow launcher and choose **Add Addon from Git**. Use:

```text
https://github.com/Foulwerp/AutoAreaLoot.git
```

The addon should be installed as:

```text
Interface/AddOns/AutoAreaLoot
```

## Commands

```text
/aal on
/aal off
/aal status
/aal log
/aal debug
/aal debug off
/aal debug clear
```

Typing `/aal` without an argument opens or closes the settings panel.
The debug window records precise trigger, scheduling, ClassicAPI scan, and loot
confirmation steps. Choose **Select All** to pause capture and select the trace,
then press `Ctrl+C` to copy a report.
