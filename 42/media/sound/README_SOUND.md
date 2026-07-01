# Sound assets (placeholder)

The mod ships with **no custom sound banks** so it loads cleanly. All sounds are
referenced by *event name* in `MortarConfig`/effect modules and currently point
at **vanilla** sound events (e.g. the large-explosion cue). Replace later:

1. Author an FMOD project + build banks (`.bank`) into this folder.
2. Register the sound events in a `media/scripts/*_sound.txt` soundbank script.
3. Swap the placeholder event names in the effect modules
   (`MortarExplosion.lua` fire/impact, `MortarFireAction.lua` tube "thunk").

See `docs/ASSET_CHECKLIST.md` for the full list of sounds to create.
