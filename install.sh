#!/bin/sh
# Symlinks this mod into Dwarf Fortress's mods folder so DFHack picks up the
# scripts in scripts_modinstalled/ directly from this checkout.
set -e
# DFHack reads mods from DF's user data folder, not the Steam install folder.
DF_DIR="${DF_DIR:-$HOME/.local/share/Bay 12 Games/Dwarf Fortress}"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$DF_DIR/mods/llm_lore"

if [ ! -d "$DF_DIR/mods" ]; then
    echo "Can't find $DF_DIR/mods; set DF_DIR to your Dwarf Fortress folder." >&2
    exit 1
fi
if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    echo "$DEST exists and is not a symlink; not touching it." >&2
    exit 1
fi
ln -sfn "$SRC" "$DEST"
echo "Linked $DEST -> $SRC"
