# Tiles / deployed sprite (placeholder)

The deployed mortar is a world `IsoObject` whose sprite is chosen per facing in
`MortarConfig.SPRITE`. To keep the mod **loadable with zero binary assets**, it
currently points at existing **vanilla sprite names** (`usePlaceholderVanilla =
true`). Nothing crashes if a name is wrong — the object stays interactable, it
just may render oddly or invisibly.

## Shipping a real sprite

1. Build a tile sheet in TileZed (top-down mortar baseplate + tube, 4 facings).
2. Export the `.tiles`/`.pack` + `tiledefinitions` into this folder and declare
   the tileset in `mod.info` (`pack=` / `tiledef=`) per the B42 tile pipeline.
3. Put the four sprite names into `MortarConfig.SPRITE.custom` and set
   `usePlaceholderVanilla = false`.

The recommended tile properties for the deployed object (design 8.3):
`solid = false`, `moveThrough = false`, `attachSurface = floor`.

## Smoke placeholder

`MortarConfig.SMOKE.placeholderSprite` names the fallback smoke sprite used only
if no native smoke spawner is found at runtime. A 1-tile translucent grey puff
texture (`Item_MortarSmoke.png` exists as an icon reference) is sufficient.
