# common/ (Build 42 mandatory shared folder)

B42 requires a `common/` folder alongside the version folder(s). It holds assets
shared across all game versions and is loaded BEFORE the version folder. This mod
keeps everything build-specific under `42/`, so this folder is intentionally
minimal. Large version-agnostic assets (final models/textures) could live here.
