-- Asks an LLM server to write evocative descriptions for items, and shows them
-- in an overlay on the item info sheet. Descriptions are saved with the world.
--@ module = true

local backend = reqscript('internal/llm-lore/backend')
local argparse = require('argparse')
local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local STORE_KEY = 'llm_lore/items'

-- Script globals persist across reloads and are shared between the CLI and
-- the overlay (both run in this script's environment).
config = config or nil
store = store or nil        -- item id (string) -> {text=, model=}; world-scoped
pending = pending or {}     -- item id -> true
errors = errors or {}       -- item id -> message
world_gen = world_gen or 0  -- bumped on unload so late responses are dropped
last_test = last_test or nil

function get_config()
    if not config then config = backend.load_config() end
    return config
end

dfhack.onStateChange[backend.MOD_ID] = function(code)
    if code == SC_WORLD_UNLOADED then
        store, pending, errors = nil, {}, {}
        world_gen = world_gen + 1
    end
end

local function get_store()
    if not store then
        store = dfhack.persistent.getWorldData(STORE_KEY, {})
    end
    return store
end

function get_entry(item_id)
    if not dfhack.isWorldLoaded() then return nil end
    return get_store()[tostring(item_id)]
end

local function save_entry(item_id, entry)
    local s = get_store()
    s[tostring(item_id)] = entry
    dfhack.persistent.saveWorldData(STORE_KEY, s)
end

---------------------------------------------------------------------------
-- prompt building

local function utf(s)
    return s and dfhack.df2utf(s) or nil
end

-- unit.sex / historical_figure.sex: 0 female, 1 male
local function sex_word(sex)
    return sex == 0 and 'female' or sex == 1 and 'male' or nil
end

local function get_maker_name(item)
    local ok, hfid = pcall(function() return item.maker end)
    if not ok or type(hfid) ~= 'number' or hfid < 0 then return nil end
    local hf = df.historical_figure.find(hfid)
    if not hf then return nil end
    local native = dfhack.translation.translateName(hf.name, false)
    local english = dfhack.translation.translateName(hf.name, true)
    local sex = sex_word(hf.sex)
    local name = utf(native)
    if native ~= english then
        -- "in the common tongue" got read as a nickname used by outsiders
        name = ('%s (the name means "%s")'):format(name, utf(english))
    end
    return sex and ('%s, %s'):format(name, sex) or name
end

local function get_site_name()
    local site = dfhack.world.getCurrentSite()
    if not site then return nil end
    return ('%s (%s)'):format(utf(dfhack.translation.translateName(site.name, false)),
        utf(dfhack.translation.translateName(site.name, true)))
end

-- The game's full description text (decorations, images, quality, ...) is
-- only available while the item's sheet is open.
local function get_sheet_description(item)
    local vs = df.global.game.main_interface.view_sheets
    if vs.active_sheet == df.view_sheet_type.ITEM then
        local selected = dfhack.gui.getSelectedItem(true)
        if selected and selected.id == item.id and #vs.raw_description > 0 then
            return utf(vs.raw_description)
        end
    end
end

local QUALITY_NAMES = {'well-crafted', 'finely-crafted', 'superior', 'exceptional', 'masterful'}
local WEAR_NAMES = {'worn', 'threadbare', 'tattered'}
local IMPROVEMENT_NAMES = {
    ART_IMAGE='an image', COVERED='a covering', RINGS_HANGING='hanging rings',
    BANDS='bands', SPIKES='spikes', SEWN_IMAGE='a sewn image',
    ILLUSTRATION='illustrations', WRITING='writing',
}
-- what the item is made of rather than decoration on it
local STRUCTURAL_IMPROVEMENTS = {CLOTH=true, THREAD=true, PAGES=true, INSTRUMENT_PIECE=true}
local MAX_DECORATIONS = 8

local function get_material(mat_type, mat_index)
    local mi = dfhack.matinfo.decode(mat_type, mat_index)
    return mi and utf(mi:toString()) or nil
end

-- Facts read straight from the item, so the model has something to stay
-- faithful to even when the item sheet isn't open.
local function get_item_facts(item)
    local facts = {}
    local itype = df.item_type[item:getType()]
    if itype then table.insert(facts, 'Type: ' .. itype:lower():gsub('_', ' ')) end
    local mat = get_material(item:getActualMaterial(), item:getActualMaterialIndex())
    if mat then table.insert(facts, 'Material: ' .. mat) end
    if item.flags.artifact then
        table.insert(facts, 'This is a named artifact, a unique masterpiece.')
    elseif QUALITY_NAMES[item:getQuality()] then
        table.insert(facts, 'Quality: ' .. QUALITY_NAMES[item:getQuality()])
    end
    if WEAR_NAMES[item.wear] then table.insert(facts, 'Condition: ' .. WEAR_NAMES[item.wear]) end
    local ok, improvements = pcall(function() return item.improvements end)
    if ok and improvements then
        local shown, extra = 0, 0
        for _, imp in ipairs(improvements) do
            local kind = df.improvement_type[imp:getType()]
            if STRUCTURAL_IMPROVEMENTS[kind] then goto continue end
            if shown >= MAX_DECORATIONS then
                extra = extra + 1
                goto continue
            end
            do
                local what = IMPROVEMENT_NAMES[kind] or (kind and kind:lower():gsub('_', ' ')) or 'decoration'
                local imat = get_material(imp.mat_type, imp.mat_index)
                local q = QUALITY_NAMES[imp.quality]
                -- for images the material is the medium, not the subject
                local fmt = (kind == 'ART_IMAGE' or kind == 'SEWN_IMAGE') and ' in %s' or ' of %s'
                table.insert(facts, ('Decorated with %s%s%s'):format(what,
                    imat and fmt:format(imat) or '', q and (' (' .. q .. ')') or ''))
                shown = shown + 1
            end
            ::continue::
        end
        if extra > 0 then
            table.insert(facts, ('...and %d further decorations'):format(extra))
        end
    end
    return facts
end

local function lower_words(s)
    -- 'DiningHall' -> 'dining hall', 'ARMOR_STAND' -> 'armor stand'
    return (s:gsub('_', ' '):gsub('(%l)(%u)', '%1 %2'):lower())
end

local function describe_unit(unit)
    local name = utf(dfhack.units.getReadableName(unit))
    if dfhack.units.isCitizen(unit) then
        local prof = utf(dfhack.units.getProfessionName(unit))
        if prof and #prof > 0 and not name:find(prof, 1, true) then
            name = ('%s, %s'):format(name, prof:lower())
        end
        name = name .. ', a citizen of the fortress'
    end
    local sex = sex_word(unit.sex)
    return sex and ('%s (%s)'):format(name, sex) or name
end

local INVENTORY_VERBS = {
    Weapon='wielded by', Worn='worn by', Hauled='being hauled by',
    Flask='carried as a waterskin by', Strapped='strapped to', StuckIn='stuck in',
    InMouth='carried in the mouth of', SewnInto='sewn into the clothing of',
}

local function describe_building(bld)
    local btype = df.building_type[bld:getType()] or 'building'
    if btype == 'Workshop' then
        return lower_words(df.workshop_type[bld:getSubtype()] or '') .. ' workshop'
    elseif btype == 'Furnace' then
        return lower_words(df.furnace_type[bld:getSubtype()] or '') .. ' furnace'
    end
    return lower_words(btype)
end

local function describe_zone(zone)
    local kind = lower_words(df.civzone_type[zone.type] or 'zone')
    local desc = kind
    if #zone.name > 0 then desc = ('%s called "%s"'):format(kind, utf(zone.name)) end
    local owner = zone.assigned_unit_id >= 0 and df.unit.find(zone.assigned_unit_id)
    if owner then desc = ('%s belonging to %s'):format(desc, describe_unit(owner)) end
    return desc
end

-- Where the item is and how it is being used right now, so descriptions can
-- place it in the life of the fortress rather than in a display case.
function get_usage_facts(item)
    local facts = {}
    local unit = dfhack.items.getHolderUnit(item)
    if unit then
        local verb = 'carried by'
        for _, inv in ipairs(unit.inventory) do
            if inv.item == item then
                verb = INVENTORY_VERBS[df.inv_item_role_type[inv.mode]] or verb
            end
        end
        table.insert(facts, ('Currently %s %s'):format(verb, describe_unit(unit)))
    end
    local container = dfhack.items.getContainer(item)
    if container and not unit then
        -- not getDescription(): bins often carry player labels like "Ammo Bin <#6>"
        local ctype = lower_words(df.item_type[container:getType()] or 'container')
        local cmat = get_material(container:getActualMaterial(), container:getActualMaterialIndex())
        table.insert(facts, ('Stored inside a %s%s'):format(cmat and (cmat .. ' ') or '', ctype))
    end
    local bld = dfhack.items.getHolderBuilding(item)
    if bld then
        local built = false
        for _, ci in ipairs(bld.contained_items) do
            if ci.item == item and ci.use_mode == 2 then built = true end
        end
        if built and bld:getType() ~= df.building_type.Workshop and bld:getType() ~= df.building_type.Furnace then
            table.insert(facts, ('Installed in the fortress as a %s'):format(describe_building(bld)))
        elseif built then
            table.insert(facts, ('Built into a %s'):format(describe_building(bld)))
        else
            table.insert(facts, ('Sitting in a %s'):format(describe_building(bld)))
        end
    end
    local pos = xyz2pos(dfhack.items.getPosition(item))
    if pos.x >= 0 and not unit then
        local at = dfhack.buildings.findAtTile(pos)
        if at and df.building_stockpilest:is_instance(at) then
            table.insert(facts, container and 'The container sits in a stockpile' or 'Lying in a stockpile')
        end
        for _, zone in ipairs(dfhack.buildings.findCivzonesAt(pos) or {}) do
            table.insert(facts, 'Located in a ' .. describe_zone(zone))
        end
    end
    local owner = dfhack.items.getOwner(item)
    if owner and owner ~= unit then
        table.insert(facts, 'Owned by ' .. describe_unit(owner))
    end
    if #facts == 0 then
        -- with no location at all, models invent one ("the archery range")
        table.insert(facts, 'Lying loose on the floor somewhere in the fortress')
    end
    if not unit then
        -- without this, models tend to invent someone using the item
        table.insert(facts, 'No one is holding or using it at the moment')
    end
    return facts
end

-- opts (optional, for experiments): system_prompt=, include_usage=false
function build_messages(item, opts)
    opts = opts or {}
    local cfg = get_config()
    -- artifacts need the readable form for their names; for everything else
    -- the undecorated form avoids quality symbols like x*<name>*x
    local name = item.flags.artifact and dfhack.items.getReadableDescription(item)
            or dfhack.items.getDescription(item, 0, false)
    -- drop player bin/barrel labels like "<#3>"
    name = name:gsub('%s*<#%d+>', '')
    local lines = {'Item: ' .. utf(name)}
    for _, fact in ipairs(get_item_facts(item)) do table.insert(lines, fact) end
    local site = get_site_name()
    if site then table.insert(lines, 'Fortress: ' .. site) end
    local maker = get_maker_name(item)
    if maker then table.insert(lines, 'Made by (in the past): ' .. maker) end
    if opts.include_usage ~= false then
        for _, fact in ipairs(get_usage_facts(item)) do table.insert(lines, fact) end
    end
    local desc = get_sheet_description(item)
    if desc then table.insert(lines, 'Game description: ' .. desc) end
    return {
        {role='system', content=opts.system_prompt or cfg.system_prompt},
        {role='user', content=table.concat(lines, '\n')},
    }
end

---------------------------------------------------------------------------
-- generation

-- Artifacts and anything a dwarf built or crafted (furniture, weapons, armor,
-- crafts, statues, ...). Raw materials like boulders, bars, wood and food
-- aren't interesting enough for the chronicler.
function is_describable(item)
    if not item then return false end
    if not get_config().only_constructed then return true end
    return item.flags.artifact or df.item_constructed:is_instance(item)
end

-- Returns the first capitalised word that doesn't start a sentence and
-- appears nowhere in the facts. Models sometimes invent a dwarf ("Durin
-- polishes it...") despite instructions; this catches nearly all of them.
function find_invented_name(text, facts)
    local known = facts:lower()
    local prev = '.'
    for word in text:gmatch('%S+') do
        local name = word:match('^["\'(]*(%u[%a\128-\255]+)')
        -- drop possessives and dashes: "Landhames\u{2019}s", "Olonfikod\u{2014}a"
        name = name and name:gsub('\u{2019}.*$', ''):gsub('\u{2014}.*$', '')
        if name and #name > 1 and not prev:find('[%.!?:]["\')]*$') and not known:find(name:lower(), 1, true) then
            return name
        end
        prev = word
    end
end

local MAX_ATTEMPTS = 2

-- Asks the model about an item, retrying once if it invents a name.
-- cb(text, err, messages). opts are passed to build_messages.
function describe(item, opts, cb)
    local cfg = get_config()
    local messages = build_messages(item, opts)
    local function attempt(n)
        backend.chat(cfg, messages, function(text, err)
            if text and n < MAX_ATTEMPTS and find_invented_name(text, messages[2].content) then
                return attempt(n + 1)
            end
            cb(text, err, messages)
        end)
    end
    attempt(1)
end

-- on_done(text, err) is optional.
function generate(item, force, on_done)
    local id = item.id
    if pending[id] then return end
    if not force and get_entry(id) then return end
    local model = get_config().model
    local gen = world_gen
    pending[id], errors[id] = true, nil
    describe(item, nil, function(text, err)
        if gen ~= world_gen then return end
        pending[id] = nil
        if err then
            errors[id] = err
            dfhack.printerr(('llm-lore: item %d: %s'):format(id, err))
        else
            save_entry(id, {text=text, model=model})
        end
        if on_done then on_done(text, err) end
    end)
end

local REPLACEMENTS = {
    ['\u{201c}']='"', ['\u{201d}']='"', ['\u{2018}']="'", ['\u{2019}']="'",
    ['\u{2014}']='--', ['\u{2013}']='-', ['\u{2026}']='...',
}

-- UTF-8 model output -> CP437 text the game can draw
function to_display(text)
    text = text:gsub('%s*\n%s*', ' ')
    for from, to in pairs(REPLACEMENTS) do text = text:gsub(from, to) end
    return dfhack.utf2df(text)
end

function get_status_text(item_id)
    local entry = get_entry(item_id)
    if pending[item_id] then
        return entry and 'The chronicler is rewriting this entry...'
                or 'The chronicler is writing...'
    end
    if errors[item_id] then
        local err = errors[item_id]
        if #err > 160 then err = err:sub(1, 160) .. '...' end
        return 'The chronicler could not be reached: ' .. to_display(err)
    end
    if entry then return to_display(entry.text) end
    return 'No chronicle entry yet.'
end

---------------------------------------------------------------------------
-- overlay

local TEXT_WIDTH = 44

LoreOverlay = defclass(LoreOverlay, overlay.OverlayWidget)
LoreOverlay.ATTRS{
    desc='Shows an LLM-written description on item sheets.',
    default_pos={x=-100, y=6},
    default_enabled=true,
    viewscreens='dwarfmode/ViewSheets/ITEM',
    frame={w=TEXT_WIDTH + 5, h=6},
    frame_style=gui.MEDIUM_FRAME,
    frame_background=gui.CLEAR_PEN,
    frame_title='Chronicle',
    overlay_onupdate_max_freq_seconds=0,
    visible=function() return is_describable(dfhack.gui.getSelectedItem(true)) end,
}

function LoreOverlay:init()
    self.item_id = -1
    self.shown = ''
    self:addviews{
        widgets.WrappedLabel{
            view_id='text',
            frame={t=0, l=0, r=0},
            text_to_wrap=function() return self.shown end,
        },
        widgets.HotkeyLabel{
            frame={b=0, l=0},
            key='CUSTOM_CTRL_R',
            label='Rewrite',
            auto_width=true,
            on_activate=function()
                local item = df.item.find(self.item_id)
                if item then generate(item, true) end
            end,
        },
    }
end

function LoreOverlay:overlay_onupdate()
    local item = dfhack.gui.getSelectedItem(true)
    local id = item and item.id or -1
    if id ~= self.item_id then
        self.item_id = id
        if is_describable(item) and get_config().auto_generate then generate(item, false) end
    end
    local text = id >= 0 and get_status_text(id) or ''
    if text ~= self.shown then
        self.shown = text
        -- WrappedLabel reserves 3 columns for a scrollbar
        local lines = #text:wrap(TEXT_WIDTH, {return_as_table=true})
        self.frame.h = lines + 4
        self:updateLayout()
    end
end

OVERLAY_WIDGETS = {chronicle=LoreOverlay}

---------------------------------------------------------------------------
-- CLI

local HELP = [[
llm-lore: LLM-written item descriptions.

Usage:
  llm-lore status            show config, server and saved-description count
  llm-lore test [prompt]     send a test prompt; result is printed when it arrives
  llm-lore describe [id]     describe the selected item (or item id)
  llm-lore rewrite [id]      regenerate the description for an item
  llm-lore clear [id|all]    forget a saved description (or all of them)
  llm-lore reload            re-read the config file

The overlay on item sheets generates descriptions automatically
(Ctrl-R to rewrite). Reposition it with gui/overlay.
]]

local function print_help()
    print(HELP)
end

local function cmd_status()
    local cfg = get_config()
    print(('config:   %s'):format(backend.get_config_path()))
    print(('server:   %s (%s api)'):format(cfg.url, cfg.api))
    print(('model:    %s'):format(cfg.model))
    print(('auto:     %s'):format(tostring(cfg.auto_generate)))
    print(('requests in flight: %d'):format(backend.num_pending()))
    if dfhack.isWorldLoaded() then
        local n = 0
        for _ in pairs(get_store()) do n = n + 1 end
        print(('descriptions saved in this world: %d'):format(n))
    end
    if last_test then
        print('last test: ' .. last_test)
    end
end

local function cmd_test(prompt)
    local cfg = get_config()
    prompt = prompt or 'In one sentence, describe a granite mug made by a dwarf.'
    last_test = 'pending...'
    local started = os.time()
    print(('Sending test prompt to %s (%s)...'):format(cfg.url, cfg.model))
    backend.chat(cfg, {{role='user', content=prompt}}, function(text, err)
        last_test = ('[%ds] %s'):format(os.time() - started, err and ('ERROR: ' .. err) or text)
        print('llm-lore test: ' .. dfhack.df2console(last_test))
    end)
end

local function get_target_item(args)
    local item = args[1] and df.item.find(tonumber(args[1])) or dfhack.gui.getSelectedItem(true)
    if not item then qerror('Please select an item or pass an item id.') end
    return item
end

local function cmd_describe(args, force)
    local item = get_target_item(args)
    if not force and get_entry(item.id) then
        print(dfhack.df2console(to_display(get_entry(item.id).text)))
        return
    end
    print(('Asking the chronicler about item %d...'):format(item.id))
    generate(item, true, function(text, err)
        if text then print(dfhack.df2console(to_display(text))) end
    end)
end

local function cmd_clear(args)
    if not dfhack.isWorldLoaded() then qerror('No world loaded.') end
    if args[1] == 'all' then
        store = {}
        dfhack.persistent.saveWorldData(STORE_KEY, store)
        print('Cleared all saved descriptions for this world.')
        return
    end
    local item = get_target_item(args)
    save_entry(item.id, nil)
    print(('Cleared description for item %d.'):format(item.id))
end

local function main(args)
    local help = false
    local positionals = argparse.processArgsGetopt(args, {
        {'h', 'help', handler=function() help = true end},
    })
    local command = table.remove(positionals, 1)
    if help or not command or command == 'help' then
        print_help()
    elseif command == 'status' then
        cmd_status()
    elseif command == 'reload' then
        config = nil
        get_config()
        print('Reloaded ' .. backend.get_config_path())
    elseif command == 'test' then
        cmd_test(#positionals > 0 and table.concat(positionals, ' ') or nil)
    elseif command == 'describe' then
        cmd_describe(positionals, false)
    elseif command == 'rewrite' then
        cmd_describe(positionals, true)
    elseif command == 'clear' then
        cmd_clear(positionals)
    else
        qerror('Unknown command: ' .. command)
    end
end

if dfhack_flags.module then
    return
end

main{...}
