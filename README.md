# CC Fire Control

CC decides **when** the Big Cannons on your Sable ship fire. **Create Radar does the tracking and aiming.**

Several times a second it takes where each barrel points right now and flies an imaginary shell with real Big Cannons physics (gravity, drag, your ship's speed). Then:

1. **Would it hit my own ship?** If yes, it never fires. A cannon only fires outward from its own side of the ship, and never through another part of your ship (anything on a swivel or physics bearing).
2. **Would it hit a target?** If the shot would pass within `HIT_RADIUS` blocks of a radar target, it fires. Moving and turning targets are followed using the radar's velocity readings.

**Autocannons** (default, `AUTOCANNON = true`): the trigger is held on for as long as the shot stays good and let go the moment it isn't. **Big cannons** (`AUTOCANNON = false`): one pulse per shot, `RELOAD` seconds apart. If the program stops or crashes, every trigger is let go.

## Build

On the ship:

- **Create Radar aiming, set up as usual:** Radar Bearing, Network Controller with a **Target Filter**, an Auto Yaw Controller and Auto Pitch Controller on each Cannon Mount, with rotation going into the controllers.
- **No Fire Controller.** This computer does the firing. If one is on the network the screen warns you.
- **One computer on the ship**, with wired modems (right-click them so they turn red) on:
  - every **Cannon Mount** (for reading where it points and firing it)
  - the **Radar Bearing** (for the target list)

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-fire-control/main/fire_control.lua startup.lua
reboot
```

It starts **SAFE**: it shows what it would do but never fires. Press **A** to arm.

| Key | |
|---|---|
| A | arm / safe |
| X | the nearest target is part of your own ship: ignore it for good |
| U | un-ignore everything |
| F | fire every cannon that's clear of your own ship right now (autocannons: a 1 second burst) |

Each cannon row shows what it's doing: `ON TARGET`, `FIRE`, `reload`, `not on target` (with how far the shot would miss, and high/low), `points at own ship`, `own ship in line`, `ship rocking`.

## Your own ship

- Your main ship is never a target.
- Separate parts of your ship (swivel/physics bearings) are detected on their own once your ship moves or turns, because they keep the same spot relative to it. Until then, or if one is missed, press **X** while it's the nearest target.
- Tell it which cannons are on which side with `SIDES` (each row on screen shows L or R):
  ```lua
  SIDES = {
    left = { "cannon_mount_4", "cannon_mount_5" },
    right = { "cannon_mount_2", "cannon_mount_3" },
  }
  ```
  A cannon only fires outward from its side, within `ARC` degrees. Cannons not in `SIDES` get their side from the layout, or set one by hand: `ARCS["cannon_mount_6"] = { center = 90, width = 160 }` (yaw in the ship's frame: 0 = +Z, 90 = -X, 180 = -Z, 270 = +X).

## Round speed

Your rounds' speed depends on barrel material and length, and the computer needs it to tell whether a shot will hit. With `AUTO_SPEED = true` it **learns it from the radar**: the radar aims for the real speed, so it finds the speed at which the barrel's aim would hit the target, and once 5 readings agree it uses (and saves) that. The screen shows "Round speed 6.0 (learned from the radar)".

`SHOT_SPEED` is the first guess **and the most it will ever learn**, so leave it at your fastest possible (9 for autocannons). To learn again from scratch, delete `/firecontrol_speed` and reboot.

## If it never says ON TARGET

Look at the miss distance on a cannon's row while the radar is aiming at a target:

- **"high"** or **"low"** every time and the round speed isn't learned yet: wait a few seconds with a target in view.
- Still not: raise `HIT_RADIUS` a little.

## Settings (top of startup.lua)

| Setting | Default | |
|---|---|---|
| `AUTOCANNON` | true | hold the trigger while on target; false = big cannons |
| `AUTO_SPEED` | true | learn the real round speed from the radar's aim |
| `SHOT_SPEED` | 9 | blocks/tick. Autocannon: base speed + bonus per barrel. Steel 3 + 1.5 per barrel (up to 4), cast iron 5 + 2 (up to 2), bronze 3 + 1.5 (up to 3). Big cannon: 2 per Powder Charge |
| `SHOT_LIFETIME` | 60 | ticks before an autocannon round vanishes: steel 60, bronze 25, cast iron 11. Targets beyond that are never shot at |
| `SHOT_GRAVITY` | -0.025 | autocannon rounds; big cannon shells -0.05 |
| `BARREL_LENGTH` | 3 | blocks from the mount to the muzzle |
| `HIT_RADIUS` | 5 | fire when the shot passes this close to a target |
| `OWN_CLEARANCE` | 8 | never fire if the shot passes this close to a part of your ship |
| `RELOAD` | 6 | big cannons: seconds between shots of one cannon |
| `STAGGER` | 0.75 | big cannons: seconds between any two shots (recoil is x40 on Sable ships) |
| `MAX_ROCK` | 8 | hold fire while the ship rocks faster than this (deg/s) |
| `MIN_RANGE` / `MAX_RANGE` | 20 / 400 | |
| `TARGETS` | Sable ships | also `PLAYER`, `HOSTILE`, `MOB`, `ANIMAL` |
| `ARC` | 160 | each cannon fires only within this arc around its side |

Updates install by themselves (every 15 min and on reboot), keeping your settings. `AUTO_UPDATE = false` turns that off.
