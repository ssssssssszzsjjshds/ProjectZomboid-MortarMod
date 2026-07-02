# Animations (placeholder)

Build 42 uses the `anims_X/` folder for the new animation format. The mod reuses
**vanilla animations** for its timed actions (configured in
`MortarConfig.ACTION.anim`):

| Action     | Placeholder anim | Notes                                   |
|------------|------------------|-----------------------------------------|
| Setup      | `Loot`           | crouched build/rummage loop             |
| Breakdown  | `Loot`           | same loop, reversed feel                |
| Drop round | `PourLiquid`     | repurposed fuel-pour loop (design 4.5)  |

To use bespoke animations: add them here, then change the anim names in
`MortarConfig.ACTION.anim`. The timed actions call `setActionAnim(...)`, so no
code changes are needed beyond the config.
