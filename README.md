# LLM Lore

A DFHack mod that asks an LLM server on your network to write evocative
descriptions of Dwarf Fortress items. When you open an item's info sheet, a
**Chronicle** panel appears beside it and fills in with a few sentences built
from the game's own description (materials, decorations, images, quality),
the maker's name and the fortress name.

Descriptions are saved with the world, so each item keeps its text.

## Install

```sh
./install.sh        # symlinks this folder to <DF>/mods/llm_lore
```

DFHack loads `scripts_modinstalled/` from any mod in `mods/`, so the mod does
not need to be activated when creating a world. Restart DF after installing.

## Configure

The first run writes `dfhack-config/mods/llm_lore/config.json` (in the DF
folder). Edit it, then run `llm-lore reload` in the DFHack console.

| key | meaning |
| --- | --- |
| `api` | `ollama` (native `/api/chat`) or `openai` (`/v1/chat/completions`: llama.cpp, LM Studio, vLLM, ...) |
| `url` | server base URL, e.g. `http://192.168.1.30:11434` (an IP: `.local` mDNS names don't resolve from DFHack) |
| `model` | model name, e.g. `gemma3:12b` |
| `system_prompt` | the instructions the model follows (change the style here) |
| `only_constructed` | only describe artifacts and built/crafted items, not raw materials like boulders, bars or wood (default `true`) |
| `auto_generate` | generate as soon as an item sheet opens (otherwise press Ctrl-R) |
| `temperature`, `max_tokens`, `timeout_seconds` | generation settings |

## Use

* Open any item's sheet. The Chronicle panel shows the description, or a
  "writing..." note while the model is busy. **Ctrl-R** rewrites it.
* Move or disable the panel with `gui/overlay` or `gui/control-panel`
  (the overlay is `llm-lore.chronicle`).
* Console commands: `llm-lore status | test | describe | rewrite | clear | reload`.

## How it works

DFHack's Lua sandbox has no `os.execute`/`io.popen`, so requests go through
DFHack's `luasocket` plugin with a tiny HTTP/1.1 client. The request is sent
and then the socket is drained a byte at a time every 5 frames, so the game
keeps running while the model writes. Connecting does block briefly, which is
unnoticeable on a LAN but could stall the game for a moment if the server is down.

## Prompt notes

The default prompt was tuned with `devel/llm-lore-eval` on gemma3:12b
(about 4 s per description; gemma3:27b was ~2.5x slower and no more accurate).
What mattered:

* **Asking for a "museum catalogue" style made every item sound like an
  exhibit.** The prompt now asks for the item as it is in daily fortress life,
  and the facts say where it is and who is wearing, wielding, carrying or
  hauling it, or which room, stockpile or bin it's in.
* **Telling the model to say who uses an item made it invent users.** The facts
  now state outright when no one is using an item, say that the maker made it
  "in the past", and give each dwarf's sex for pronouns. Items with no location
  at all are reported as "lying loose on the floor"; otherwise the model invents
  a place.
* **Rules against invented events and places** (raids, cave-ins, burials,
  treasuries) cut those out with no loss of flavour.
* **A name check backs up the prompt.** If the text contains a capitalised word
  that appears nowhere in the facts and doesn't start a sentence (nearly always
  an invented dwarf), the description is regenerated once.

### Running an eval

```
devel/llm-lore-eval /path/to/spec.json
```

The spec lists item ids, prompt variants (`system_prompt`, `include_usage`,
`model`, `no_retry`) and an output path. Results, including the facts sent to
the model, are written as JSON. Nothing is saved to the world.

## Development

Edit files in place (they're symlinked), then in the DFHack console:

```
:lua require('plugins.overlay').rescan()
```
