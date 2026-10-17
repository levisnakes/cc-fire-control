# CC Fire Control

CC decides **when** the Big Cannons on your Sable ship fire. **Create Radar does the tracking and aiming.**

Several times a second it takes where each barrel points right now and flies an imaginary shell with real Big Cannons physics (gravity, drag, your ship's speed). Then:

1. **Would it hit my own ship?** If yes, it never fires. A cannon only fires outward from its own side of the ship, and never through another part of your ship (anything on a swivel or physics bearing).
2. **Would it hit a target?** If the shell would pass within `HIT_RADIUS` blocks of a radar target, it fires. Moving and turning targets are followed using the radar's velocity readings.

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
| F | fire every cannon that's clear of your own ship right now |

Each cannon row shows what it's doing: `ON TARGET`, `FIRE`, `reload`, `not on target` (with how far the shot would miss, and high/low), `points at own ship`, `own ship in line`, `ship rocking`.

## Your own ship

- Your main ship is never a target.
- Separate parts of your ship (swivel/physics bearings) are detected on their own once your ship moves or turns, because they keep the same spot relative to it. Until then, or if one is missed, press **X** while it's the nearest target.
- Each cannon's side is worked out from how the cannons are laid out (two per side). If a cannon's side comes out wrong, set it by hand: `ARCS["cannon_mount_2"] = { center = 90, width = 160 }` (yaw in the ship's frame: 0 = +Z, 90 = -X, 180 = -Z, 270 = +X).

## If it never says ON TARGET

Look at the miss distance on a cannon's row while the radar is aiming at a target:

- **"high"** every time: your shells are faster than it thinks. Raise `CANNON_SPEED`.
- **"low"** every time: lower `CANNON_SPEED`.

`CANNON_SPEED` is 2 per Powder Charge (4 charges = 8). Or raise `HIT_RADIUS` a little.

## Settings (top of startup.lua)

| Setting | Default | |
|---|---|---|
| `CANNON_SPEED` | 8 | shell speed, blocks/tick |
| `BARREL_LENGTH` | 4 | blocks from the mount to the muzzle |
| `HIT_RADIUS` | 5 | fire when the shot passes this close to a target |
| `OWN_CLEARANCE` | 8 | never fire if the shot passes this close to a part of your ship |
| `RELOAD` | 6 | seconds between shots of one cannon (match your autoloader) |
| `STAGGER` | 0.75 | seconds between any two shots (recoil is x40 on Sable ships) |
| `MAX_ROCK` | 8 | hold fire while the ship rocks faster than this (deg/s) |
| `MIN_RANGE` / `MAX_RANGE` | 20 / 400 | |
| `TARGETS` | Sable ships | also `PLAYER`, `HOSTILE`, `MOB`, `ANIMAL` |
| `ARC` | 160 | each cannon fires only within this arc around its side |

Updates install by themselves (every 15 min and on reboot), keeping your settings. `AUTO_UPDATE = false` turns that off.
