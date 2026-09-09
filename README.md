# AutoAreaLoot

AutoAreaLoot automatically loots nearby corpses when it is safe to do so.

## Behavior

- Loots nearby corpses when an NPC death event fires
- Individually configurable death and movement-stop triggers
- Optional in-combat looting, enabled by default
- Coalesces combat triggers into one final loot pass when combat ends
- Avoids interrupting manual loot windows
- Coalesces death bursts and ignores new triggers while a ClassicAPI loot walk is already active
- Closing a manual loot window does not start another area-loot pass
- `/aal` opens a small settings panel with enable, death, movement-stop, and combat toggles
- `/aal log` opens a compact, scrollable session loot log
- Confirms item loot from the player's localized loot messages and filters it against the corpse scan
- Shows money totals and optionally combines matching item rows
- Shows newest loot first when rows are uncombined
- Supports resizing the loot log down to a compact minimum size
- Remembers the loot log's size and screen position
- Can optionally open the loot log automatically on login or `/reload`
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
```

Typing `/aal` without an argument opens or closes the settings panel.
