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
| `rewrite_on_change` | rewrite a description when the item changes hands, moves to another room, building or stockpile, wears, or gains decorations (default `true`) |
| `auto_generate` | generate as soon as an item sheet opens (otherwise press Ctrl-R) |
| `temperature`, `max_tokens`, `timeout_seconds` | generation settings |

## Use

* Open any item's sheet. The Chronicle panel shows its description, or a
  "writing..." note while the model is busy. **Ctrl-R** rewrites it.
* If the item has changed hands or moved since its description was written,
  the old text stays up, marked as updating, while a new one is written.
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
* **Asking for "wear and traces" made everything dusty and scratched,** and
  every description fell into one formula: place, then "the maker shaped it
  with care, but now...", then "a hauler just bumped it". What fixed it:
  * stating the item's real condition (usually "in good repair, no wear")
  * saying what each room is for (a meeting hall is where dwarves drink and
    dance, not where they "discuss mining quotas") and what each stockpile
    holds; taverns, temples, hospitals and the like come through by name
  * giving each description one randomly chosen focus (material, daily use,
    surroundings, the dwarf who has it, craftsmanship); books always focus on
    their contents
* **Length follows what there is to say:** one or two sentences for everyday
  items, two or three for fine or decorated ones, three or four for artifacts,
  and four to six for books, whose title, genre, author, style and subjects
  (civilizations, figures, historical events) are read from the game. Giving
  artifacts six sentences with nothing to fill them made the model invent.
* **Personality makes owners and wearers into people.** Without it the model
  guessed ("he's asked for better boots") or fell back on generic contentment.
  Each dwarf who holds the item, owns it, or owns its room (never the maker)
  gets one line, built in `internal/llm-lore/personality.lua`:
  * two facets picked at random from their four most extreme (a fixed set made
    the anxious duke pace in five of his six items)
  * their strongest value
  * their dream, only if it's an unusual one (four common dreams covered 92% of
    dwarves, and naming them made every description wistful about family)
  * any like that matches this item. Dwarves keep items they like, so this is
    often the real reason they have it ("is fond of crowns and carries 8 of them")

  Thoughts, moods and needs are left out: they change daily, and a saved
  description would soon be wrong. Dead tomb owners are marked as dead and
  described "in life". Invented feelings are welcome if they follow from the
  facts.
* **A check backs up the prompt.** Garbled first names next to a correct
  surname ("Mettob Nirezum") are corrected in place. If the text contains a
  capitalised word that appears nowhere in the facts and doesn't start a
  sentence, or a full name half of which is unknown (nearly always an invented
  dwarf), or a stock phrase like "a testament to" or "a reminder of",
  the description is regenerated, up to three tries. If every try has a problem,
  the offending sentences after the first are dropped.

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
