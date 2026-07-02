# Models

The mortar ships with real 3D static models (binary FBX v7400, Y-up,
triangulated, single material), all textured by
`media/textures/M224_Mortar.png` (procedural olive-drab metal — swap for real
art anytime):

| File | Model script | Used for |
|------|--------------|----------|
| `M224_Mortar.fbx` | `MortarSystem.M224MortarWhole` | The carry item dropped on the ground (`WorldStaticModel`). Both parts merged into one mesh. |
| `M224_Baseplate.fbx` | `MortarSystem.M224Baseplate` | Deployed static baseplate part. |
| `M224_TubeAssembly.fbx` | `MortarSystem.M224TubeAssembly` | Deployed tube+bipod part, rotated to the aim bearing. |

Model scripts live in `media/scripts/models_mortar.txt` (scale knob there).

## How the deployed mortar renders

Deployment spawns an **invisible interactable anchor** IsoObject (holds all
modData/state, drives the context menu) plus **two world inventory items**
tagged in modData whose `WorldStaticModel` renders the parts in 3D
(`MortarObject.lua`, "3D PART VISUALS" section). The tube item's Z-rotation is
set from the aim bearing whenever a fire solution is applied ("Use Plotted
Solution" or firing). Visual mapping tunables (`tubeYawSign`/`tubeYawOffset`)
and the master switch (`Config.MODEL.enabled`, set `false` to return to the
legacy 2D placeholder sprites) live in `MortarConfig.lua`.

## Mesh conventions (if you re-export)

* The tube assembly's **origin must sit at the hinge** (base of the tube):
  yaw rotation happens around the model origin's vertical axis.
* Ground contact at y = 0, Y-up, triangulated faces, one material.
* The source meshes are ~19 units tall (tube); model-script `scale = 0.025`
  puts the deployed tube at roughly half a meter in world units.

The original combined export is kept at the repo root (`M224_Mortar.fbx`
upload); the three files here were split/triangulated/grounded from it
programmatically.
