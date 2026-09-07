# AutoAreaLoot

AutoAreaLoot automatically loots nearby corpses when it is safe to do so.

## Behavior

- Loots nearby corpses when an NPC death event fires
- Can loot immediately during combat or wait until combat ends
- Optionally loots nearby corpses when movement stops out of combat
- Avoids interrupting manual loot windows
- Coalesces death bursts and ignores new triggers while a ClassicAPI loot walk is already active
- Closing a manual loot window does not start another area-loot pass
- `/aal` opens a small settings panel with enable, combat, and out-of-combat toggles
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
```

Typing `/aal` without an argument opens or closes the settings panel.
