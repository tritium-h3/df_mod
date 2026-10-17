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

local function lower_words(s)
    -- 'DiningHall' -> 'dining hall', 'ARMOR_STAND' -> 'armor stand'
    return (s:gsub('_', ' '):gsub('(%l)(%u)', '%1 %2'):lower())
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
    -- stating good repair outright stops every item coming out dusty and scratched
    table.insert(facts, 'Condition: ' .. (WEAR_NAMES[item.wear] or 'in good repair, no wear'))
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

-- What each kind of room is for; models guess badly from the bare names
-- (meeting halls became places to "discuss mining quotas").
local ZONE_PURPOSES = {
    MeetingHall='where dwarves gather to drink, talk, idle and dance',
    DiningHall='where dwarves eat their meals', Dormitory='where dwarves without rooms sleep',
    Bedroom='a private sleeping room', Office='where a noble or administrator works and receives visitors',
    Barracks='where a military squad trains, sleeps and keeps its gear',
    ArcheryRange='where marksdwarves practice shooting', Tomb='where the dead are laid to rest',
    Dungeon='where prisoners are held', Pen='where animals are kept',
    WaterSource='where dwarves draw water', Shrine='a small place of worship',
    Dump='where refuse is thrown', AnimalTraining='where animals are trained',
}
local LOCATION_KINDS = {
    INN_TAVERN={'tavern', 'where dwarves drink, dance and hear performers'},
    TEMPLE={'temple', 'where dwarves pray'}, LIBRARY={'library', 'where scholars read and write'},
    HOSPITAL={'hospital', 'where the injured are treated'}, GUILDHALL={'guildhall', 'home of a craft guild'},
}

-- taverns, temples, libraries etc. are "locations" attached to a zone
local function describe_location(zone)
    if zone.location_id < 0 then return nil end
    local site = df.world_site.find(zone.site_id)
    if not site then return nil end
    for _, ab in ipairs(site.buildings) do
        if ab.id == zone.location_id then
            local kind = df.abstract_building_type[ab:getType()]
            local info = LOCATION_KINDS[kind] or {lower_words(kind or 'location')}
            local desc = 'a ' .. info[1]
            local ok, name = pcall(function() return dfhack.translation.translateName(ab:getName(), true) end)
            if ok and name and #name > 0 then desc = ('%s called "%s"'):format(desc, utf(name)) end
            return info[2] and ('%s, %s'):format(desc, info[2]) or desc
        end
    end
end

local function describe_zone(zone)
    local location = describe_location(zone)
    if location then return location end
    local kind = df.civzone_type[zone.type] or 'zone'
    local desc = 'a ' .. lower_words(kind)
    if #zone.name > 0 then desc = ('%s called "%s"'):format(desc, utf(zone.name)) end
    local owner = zone.assigned_unit_id >= 0 and df.unit.find(zone.assigned_unit_id)
    if owner then desc = ('%s belonging to %s'):format(desc, describe_unit(owner)) end
    if ZONE_PURPOSES[kind] then desc = ('%s, %s'):format(desc, ZONE_PURPOSES[kind]) end
    return desc
end

local STOCKPILE_NAMES = {
    animals='animals', food='food', furniture='furniture', corpses='corpses', refuse='refuse',
    stone='stone', ammo='ammunition', coins='coins', bars_blocks='bars and blocks', gems='gems',
    finished_goods='finished goods', leather='leather', cloth='cloth', wood='wood',
    weapons='weapons', armor='armor', sheet='paper and parchment',
}

-- what the stockpile is set to hold; without this, models invent one
function describe_stockpile(pile)
    local kinds = {}
    for flag, on in pairs(pile.settings.flags) do
        if on and STOCKPILE_NAMES[flag] then table.insert(kinds, STOCKPILE_NAMES[flag]) end
    end
    table.sort(kinds)
    if #kinds == 0 or #kinds > 3 then return 'a general stockpile' end
    if #kinds == 1 then return ('a stockpile for %s'):format(kinds[1]) end
    return ('a stockpile for %s and %s'):format(table.concat(kinds, ', ', 1, #kinds - 1), kinds[#kinds])
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
            local pile = describe_stockpile(at)
            table.insert(facts, container and ('The container sits in ' .. pile) or ('Lying in ' .. pile))
        end
        for _, zone in ipairs(dfhack.buildings.findCivzonesAt(pos) or {}) do
            table.insert(facts, 'Located in ' .. describe_zone(zone))
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

---------------------------------------------------------------------------
-- books and other written works

local function entity_desc(id)
    local e = df.historical_entity.find(id)
    if not e then return nil end
    local race = df.creature_raw.find(e.race)
    return ('%s (%s%s)'):format(utf(dfhack.translation.translateName(e.name, true)),
        race and (race.name[2] .. ' ') or '', lower_words(df.historical_entity_type[e.type] or 'group'))
end

local function site_desc(id)
    local site = df.world_site.find(id)
    return site and utf(dfhack.translation.translateName(site.name, true)) or nil
end

local function hf_desc(id)
    local hf = df.historical_figure.find(id)
    return hf and utf(dfhack.translation.translateName(hf.name, true)) or nil
end

-- event fields that commonly name the parties and place involved
local EVENT_ENTITY_FIELDS = {'source', 'destination', 'civ', 'victim_entity',
                             'attacker_civ', 'defender_civ', 'entity'}

-- readable names for event types books commonly cover; others fall back to
-- the enum name ('HF_DIED' -> 'hf died')
local EVENT_NAMES = {
    WAR_PEACE_ACCEPTED='a peace treaty accepted', WAR_PEACE_REJECTED='a peace offer rejected',
    BODY_ABUSED='the desecration of bodies', HIST_FIGURE_DIED='a death',
    WAR_FIELD_BATTLE='a battle', WAR_ATTACKED_SITE='an attack on a settlement',
    WAR_DESTROYED_SITE='the destruction of a settlement', CREATED_SITE='the founding of a settlement',
    ENTITY_CREATED='the founding of a civilization', ARTIFACT_CREATED='the making of an artifact',
    MASTERPIECE_CREATED_ITEM='the making of a masterpiece', CREATURE_DEVOURED='a creature devouring its victim',
    HIST_FIGURE_ABDUCTED='an abduction', WAR_SITE_TAKEN_OVER='the conquest of a settlement',
}

local function event_desc(ev)
    local parts = {}
    for _, field in ipairs(EVENT_ENTITY_FIELDS) do
        local ok, id = pcall(function() return ev[field] end)
        local name = ok and type(id) == 'number' and id >= 0 and entity_desc(id)
        if name then table.insert(parts, name) end
    end
    local ok, site_id = pcall(function() return ev.site end)
    local site = ok and type(site_id) == 'number' and site_id >= 0 and site_desc(site_id)
    local etype = df.history_event_type[ev:getType()]
    return ('%s in the year %d%s%s'):format(EVENT_NAMES[etype] or lower_words(etype or 'an event'),
        ev.year, #parts > 0 and (', involving ' .. table.concat(parts, ' and ')) or '',
        site and (', at ' .. site) or '')
end

local function written_content_facts(wc)
    local facts = {}
    local author = wc.author >= 0 and hf_desc(wc.author)
    table.insert(facts, ('Contains "%s", a %s%s'):format(utf(wc.title),
        lower_words(df.written_content_type[wc.type] or 'work'), author and (' by ' .. author) or ''))
    local styles = {}
    for i, style in ipairs(wc.styles) do
        local name = df.written_content_style[style]
        if name then
            local strength = wc.style_strength[i]
            table.insert(styles, (strength == 2 and 'very ' or strength == 0 and 'somewhat ' or '') .. lower_words(name))
        end
    end
    if #styles > 0 then table.insert(facts, 'Its writing is ' .. table.concat(styles, ', ')) end
    for _, ref in ipairs(wc.refs) do
        local rtype = df.general_ref_type[ref:getType()]
        local desc
        if rtype == 'ENTITY' then
            desc = entity_desc(ref.entity_id)
        elseif rtype == 'HISTORICAL_EVENT' then
            local ev = df.history_event.find(ref.event_id)
            desc = ev and event_desc(ev)
        elseif rtype == 'HISTORICAL_FIGURE' then
            desc = hf_desc(ref.hist_figure_id)
        elseif rtype == 'SITE' then
            desc = site_desc(ref.site_id)
        end
        if desc then table.insert(facts, 'It concerns ' .. desc) end
    end
    return facts
end

-- Title, genre, author, style and subjects of anything written in the item.
local function get_written_facts(item)
    local facts = {}
    local ok, improvements = pcall(function() return item.improvements end)
    if not ok or not improvements then return facts end
    for _, imp in ipairs(improvements) do
        local has, contents = pcall(function() return imp.contents end)
        if has and contents then
            for _, wcid in ipairs(contents) do
                local wc = df.written_content.find(wcid)
                if wc then
                    local wok, wfacts = pcall(written_content_facts, wc)
                    if wok then
                        for _, f in ipairs(wfacts) do table.insert(facts, f) end
                    end
                end
            end
        end
    end
    return facts
end

---------------------------------------------------------------------------
-- how much to write

local LENGTHS = {
    'Length: one or two short sentences, under 35 words. This is an everyday item.',
    'Length: two or three sentences, under 70 words.',
    'Length: three or four sentences, under 100 words.',
    'Length: four to six sentences, under 150 words. Give its contents room.',
}

-- 1 = everyday, 2 = notable, 3 = artifact, 4 = has written contents.
-- Length follows what there is to say: artifacts without contents padded
-- out to six sentences by inventing things.
function get_importance(item, written_facts)
    if #written_facts > 0 then return item.flags.artifact and 4 or 3 end
    if item.flags.artifact then return 3 end
    if item:getQuality() >= 3 then return 2 end  -- superior or better
    local ok, improvements = pcall(function() return item.improvements end)
    if ok and improvements then
        for _, imp in ipairs(improvements) do
            if not STRUCTURAL_IMPROVEMENTS[df.improvement_type[imp:getType()]] then return 2 end
        end
    end
    return 1
end

-- One angle per description, so they don't all follow the same
-- place -> maker -> recent-incident formula.
local FOCUSES = {
    material='the look, feel, weight or sound of its material',
    use='how it is used in the fortress day to day',
    place='the place around it and what goes on there',
    person='the dwarf who has it, and what the item is to them',
    craft='its craftsmanship and its maker',
    contents='what is written in it: its title, genre, author and subjects',
}

local function choose_focus(item, has_maker, importance, has_writing)
    if has_writing then return 'contents' end
    local options = {'material', 'use', 'place'}
    if dfhack.items.getHolderUnit(item) or dfhack.items.getOwner(item) then
        table.insert(options, 'person')
        table.insert(options, 'person') -- people are usually the most interesting angle
    end
    if has_maker and importance >= 2 then table.insert(options, 'craft') end
    return options[math.random(#options)]
end

-- opts (optional, for experiments): system_prompt=, include_usage=false, focus=
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
    local written = get_written_facts(item)
    local importance = get_importance(item, written)
    local maker = get_maker_name(item)
    local focus = opts.focus or choose_focus(item, maker ~= nil, importance, #written > 0)
    -- everyday items only credit the maker when that's the point
    if maker and (importance >= 2 or focus == 'craft') then
        table.insert(lines, 'Made by (in the past): ' .. maker)
    end
    if opts.include_usage ~= false then
        for _, fact in ipairs(get_usage_facts(item)) do table.insert(lines, fact) end
    end
    for _, fact in ipairs(written) do table.insert(lines, fact) end
    local desc = get_sheet_description(item)
    if desc then table.insert(lines, 'Game description: ' .. desc) end
    table.insert(lines, 'Focus: ' .. FOCUSES[focus])
    table.insert(lines, LENGTHS[importance])
    return {
        {role='system', content=opts.system_prompt or cfg.system_prompt},
        {role='user', content=table.concat(lines, '\n')},
    }
end

---------------------------------------------------------------------------
-- generation

-- A compact record of the item's situation: who has it and how, who owns it,
-- where it is, its wear and decorations. Uses ids rather than text so that,
-- say, a dwarf changing profession doesn't count as a change. Returns nil
-- while the item is in transit (being hauled, or inside something carried),
-- since that's temporary.
function get_fingerprint(item)
    local parts = {}
    local unit = dfhack.items.getHolderUnit(item)
    if unit then
        local role
        for _, inv in ipairs(unit.inventory) do
            if inv.item == item then role = df.inv_item_role_type[inv.mode] end
        end
        if not role or role == 'Hauled' then return nil end
        table.insert(parts, ('u%d:%s'):format(unit.id, role))
    end
    local owner = dfhack.items.getOwner(item)
    if owner then table.insert(parts, 'o' .. owner.id) end
    local bld = dfhack.items.getHolderBuilding(item)
    if bld then table.insert(parts, 'b' .. bld.id) end
    if not unit then
        local pos = xyz2pos(dfhack.items.getPosition(item))
        if pos.x >= 0 then
            local at = dfhack.buildings.findAtTile(pos)
            if at and df.building_stockpilest:is_instance(at) then table.insert(parts, 's' .. at.id) end
            for _, zone in ipairs(dfhack.buildings.findCivzonesAt(pos) or {}) do
                table.insert(parts, 'z' .. zone.id)
            end
        end
    end
    table.insert(parts, 'w' .. item.wear)
    local ok, improvements = pcall(function() return item.improvements end)
    table.insert(parts, 'i' .. (ok and improvements and #improvements or 0))
    return table.concat(parts, ',')
end

-- true if the item's situation has changed since its description was written
function is_stale(item, entry)
    if not entry or not get_config().rewrite_on_change then return false end
    local fp = get_fingerprint(item)
    if not fp then return false end
    if not entry.fingerprint then
        -- written before fingerprints existed: adopt the current one rather
        -- than rewriting everything at once
        entry.fingerprint = fp
        save_entry(item.id, entry)
        return false
    end
    return entry.fingerprint ~= fp
end

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

local MAX_ATTEMPTS = 3

-- tics the prompt asks against but the model still slips into
local BANNED_PHRASES = {'testament', 'speaks of', 'reminder of', 'evidence of', 'souvenir',
                        'simple thing', 'practical thing'}

-- Returns why a description should be regenerated, or nil if it's fine.
function find_problem(text, facts)
    local name = find_invented_name(text, facts)
    if name then return 'invented name: ' .. name end
    local lower = text:lower()
    for _, phrase in ipairs(BANNED_PHRASES) do
        if lower:find(phrase, 1, true) then return 'banned phrase: ' .. phrase end
    end
end

-- Last resort when every attempt had a problem: drop the sentences that
-- have one, as long as something is left.
function drop_problem_sentences(text, facts)
    local kept = {}
    for sentence in text:gmatch('[^%.!?]+[%.!?]+["\']?%s*') do
        if not find_problem(sentence, facts) then table.insert(kept, sentence) end
    end
    if #kept == 0 then return text end
    return (table.concat(kept):gsub('%s+$', ''))
end

-- Asks the model about an item, retrying if it invents a name or uses a
-- banned phrase. cb(text, err, messages). opts are passed to build_messages.
function describe(item, opts, cb)
    local cfg = get_config()
    local messages = build_messages(item, opts)
    local function attempt(n)
        backend.chat(cfg, messages, function(text, err)
            if text and find_problem(text, messages[2].content) then
                if n < MAX_ATTEMPTS then return attempt(n + 1) end
                text = drop_problem_sentences(text, messages[2].content)
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
    -- taken now, so it matches the facts the description is written from
    local fingerprint = get_fingerprint(item)
    pending[id], errors[id] = true, nil
    describe(item, nil, function(text, err)
        if gen ~= world_gen then return end
        pending[id] = nil
        if err then
            errors[id] = err
            dfhack.printerr(('llm-lore: item %d: %s'):format(id, err))
        else
            save_entry(id, {text=text, model=model, fingerprint=fingerprint})
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
        return entry and (to_display(entry.text) .. ' [The chronicler is updating this entry...]')
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
    default_pos={x=-99, y=5},
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
    -- also recheck periodically: reopening the same item doesn't change the
    -- selection, and its situation may have changed in the meantime
    local now = dfhack.getTickCount() / 1000
    if id ~= self.item_id or now - (self.checked_at or 0) > 2 then
        self.item_id, self.checked_at = id, now
        if is_describable(item) then
            local entry = get_entry(id)
            if is_stale(item, entry) then
                generate(item, true)
            elseif get_config().auto_generate then
                generate(item, false)
            end
        end
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
