# Auto Area Loot

Auto Area Loot automatically loots nearby corpses when it is safe to do so.

## Behavior

- Loots nearby corpses when an NPC death event fires
- Loots nearby corpses when movement stops
- Avoids interrupting manual loot windows
- Slash commands enable, disable, or report the addon status

## API requirement

Auto Area Loot requires the `C_Loot.LootAllCorpses` function provided by the ClassicAPI DLL. It checks for that function at runtime and displays a chat message if it is unavailable.

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
