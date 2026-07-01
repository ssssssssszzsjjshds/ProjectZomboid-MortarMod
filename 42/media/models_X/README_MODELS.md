# Models (placeholder)

Build 42 uses the `models_X/` folder for the new model format. The mortar is
currently rendered as a **2D tile sprite** (see `media/tiles/` and
`MortarConfig.SPRITE`), so no 3D model is required for the mod to function.

If you later want a 3D deployed mortar or a held model for the carry item:

1. Drop `.fbx`/`.txt` model definitions here under `models_X/`.
2. Reference the model from the item script (`WorldStaticModel = ...`) and/or
   from the deployed object creation in `MortarObject.create`.

The carry item currently uses the vanilla `Crate` world model as a placeholder.
