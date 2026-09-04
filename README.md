# MacroSwap

<p align="center"><img src="logo.svg" width="140" alt="MacroSwap logo"></p>

A World of Warcraft addon for TBC Classic (Anniversary) that swaps a macro's
text based on your current target — automatically, and without touching
protected actions, so it keeps working in combat.

Set up as many independent swaps as you like: a different macro for trash
vs. bosses, a fight-specific trinket macro that only activates on one boss,
a per-target CC macro, whatever you need.

## What it does

Each MacroSwap "tab" is one rule:

- **Original macro** — a macro already on your action bar.
- **Swap-in macro** — a second macro (doesn't need to be on any bar) whose
  text gets copied into the original while the rule is active.
- **Target** — what the rule watches for. Three modes:
  - **Specific** — a literal target name you type in.
  - **Boss** — matches any recognized Classic or TBC dungeon/raid boss.
  - **Trash** — matches any hostile, attackable NPC that *isn't* a
    recognized boss.

While the target condition is true, your original macro's text (and icon)
is replaced with the swap-in macro's. The moment it's no longer true, the
original text is restored. Your keybind and action bar placement never
change — only the macro's contents do.

## Install

1. Grab the zip from the [latest release](https://github.com/scbasss/MacroSwap/releases/latest)
   (not GitHub's "Code → Download ZIP" button — that one names the folder
   `MacroSwap-master`, which won't load; the release zip is already named
   and structured correctly).
2. Extract it into your WoW `Interface/AddOns/` directory, so you end up
   with `Interface/AddOns/MacroSwap/MacroSwap.toc`.
3. `/reload` or restart the game.

## Usage

- `/macroswap` opens the options window.
- Click `+` to add a new tab, `Remove This Tab` to delete the current one.
- Fill in Original macro, Swap-in macro, and pick a target mode.
- That's it — everything saves as you type, no confirm/apply step.

Config is stored per-character.

## How the boss/trash database works

`BossList.lua` is a plain Lua table (`MacroSwap_Bosses`) of lowercase boss
names covering Classic and TBC 5-man dungeons, raids, and notable world
bosses. If a boss is missing or misspelled, it's just a flat table — open
the file and edit it directly, no code changes needed.

## Known limitation: combat lockdown

Blizzard blocks macro edits (`EditMacro`) while you're in combat — this is
enforced by the game client itself, not something an addon can work around.
Practically, that means:

- The first swap has to happen before you enter combat (e.g. target the
  boss right before the pull).
- If you switch targets mid-fight in a way that *would* change the macro,
  the change is queued and applied automatically the instant combat ends,
  not while you're still fighting.

For "Boss" and "Trash" modes this is rarely an issue in practice, since you
typically acquire the relevant target right before a pull, while still out
of combat.

## License

All rights reserved. See [LICENSE](LICENSE).
