# Auto Area Loot

Auto Area Loot automatically loots nearby corpses when it is safe to do so.

## Behavior

- Loots nearby corpses when an NPC dies
- Loots nearby corpses when movement stops
- Avoids interrupting manual loot windows
- One minimap toggle enables or disables automatic looting

## API requirement

Auto Area Loot requires the `C_Loot.LootAllCorpses` function provided by `!!!ClassicAPI`. It checks for that function at runtime and displays a chat message if it is unavailable.

`NampowerSettings` / Nampower is optional and provides a more reliable death event.

## Installation

Use the Twow/Octowow launcher and choose **Add Addon from Git**. Use:

```text
https://github.com/Foulwerp/AutoAreaLoot.git
```

The addon should be installed as:

```text
Interface/AddOns/AutoAreaLoot
```

## Settings

Click the Auto Area Loot coin icon on the minimap and toggle **Enable automatic looting**. Drag the icon to reposition it.
