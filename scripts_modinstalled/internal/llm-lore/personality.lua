-- Turns a dwarf's stable personality data into one short line of facts for
-- the prompt. Only lasting traits are used (personality facets, values,
-- dreams, likes); thoughts, moods and needs change too often to bake into a
-- saved description.
--@ module = true

-- personality facet -> {phrase when high, phrase when low}
local FACETS = {
    LOVE_PROPENSITY={'falls in love easily', 'slow to love'},
    HATE_PROPENSITY={'quick to hate', 'slow to hate'},
    ENVY_PROPENSITY={'often envious', 'never envious'},
    CHEER_PROPENSITY={'cheerful', 'rarely cheerful'},
    DEPRESSION_PROPENSITY={'prone to gloom', 'never gloomy'},
    ANGER_PROPENSITY={'quick-tempered', 'slow to anger'},
    ANXIETY_PROPENSITY={'anxious', 'calm and unworried'},
    LUST_PROPENSITY={'lustful', 'uninterested in lust'},
    STRESS_VULNERABILITY={'easily stressed', 'unflappable under stress'},
    GREED={'greedy', 'cares little for wealth'},
    IMMODERATION={'given to excess', 'temperate'},
    VIOLENT={'given to violence', 'abhors violence'},
    PERSEVERANCE={'stubbornly persistent', 'gives up easily'},
    WASTEFULNESS={'wasteful', 'thrifty'},
    DISCORD={'quarrelsome', 'a peacemaker'},
    FRIENDLINESS={'friendly', 'unfriendly'},
    POLITENESS={'polite', 'rude'},
    DISDAIN_ADVICE={'scorns advice', 'relies on advice'},
    BRAVERY={'brave', 'cowardly'},
    CONFIDENCE={'confident', 'unsure of themself'},
    VANITY={'vain about their looks', 'indifferent to their looks'},
    AMBITION={'ambitious', 'unambitious'},
    GRATITUDE={'grateful', 'ungrateful'},
    IMMODESTY={'showy', 'modest'},
    HUMOR={'loves a joke', 'humorless'},
    VENGEFUL={'vengeful', 'forgiving'},
    PRIDE={'proud', 'humble'},
    CRUELTY={'cruel', 'kind-hearted'},
    SINGLEMINDED={'single-minded', 'easily distracted'},
    HOPEFUL={'hopeful', 'pessimistic'},
    CURIOUS={'curious', 'incurious'},
    BASHFUL={'bashful', 'bold with others'},
    PRIVACY={'private', 'open about themself'},
    PERFECTIONIST={'a perfectionist', 'careless of details'},
    CLOSEMINDED={'closed-minded', 'open-minded'},
    TOLERANT={'tolerant', 'intolerant'},
    EMOTIONALLY_OBSESSIVE={'clings to feelings', 'lets feelings go'},
    SWAYED_BY_EMOTIONS={'ruled by emotion', 'unmoved by emotion'},
    ALTRUISM={'selfless', 'selfish'},
    DUTIFULNESS={'dutiful', 'disdains duty'},
    THOUGHTLESSNESS={'rash', 'cautious'},
    ORDERLINESS={'orderly', 'messy'},
    TRUST={'trusting', 'distrustful'},
    GREGARIOUSNESS={'loves company', 'prefers solitude'},
    ASSERTIVENESS={'assertive', 'passive'},
    ACTIVITY_LEVEL={'energetic', 'sluggish'},
    EXCITEMENT_SEEKING={'thrill-seeking', 'avoids excitement'},
    IMAGINATION={'imaginative', 'unimaginative'},
    ABSTRACT_INCLINED={'drawn to ideas', 'down-to-earth'},
    ART_INCLINED={'loves art', 'indifferent to art'},
}

local VALUES = {
    LAW='the law', LOYALTY='loyalty', FAMILY='family', FRIENDSHIP='friendship',
    POWER='power', TRUTH='honesty', CUNNING='cunning', ELOQUENCE='eloquence',
    FAIRNESS='fairness', DECORUM='decorum', TRADITION='tradition', ARTWORK='art',
    COOPERATION='cooperation', INDEPENDENCE='independence', STOICISM='stoicism',
    INTROSPECTION='introspection', SELF_CONTROL='self-control', TRANQUILITY='tranquility',
    HARMONY='harmony', MERRIMENT='merriment', CRAFTSMANSHIP='craftsmanship',
    MARTIAL_PROWESS='martial prowess', SKILL='skill', HARD_WORK='hard work',
    SACRIFICE='sacrifice', COMPETITION='competition', PERSEVERANCE='perseverance',
    LEISURE_TIME='leisure', COMMERCE='commerce', ROMANCE='romance', NATURE='nature',
    PEACE='peace', KNOWLEDGE='knowledge',
}

-- Only unusual dreams are worth a mention: in a sample fort, creating great
-- art, mastering a skill, starting a family and crafting a masterwork covered
-- 92% of dwarves, and naming them just made every description wistful.
local DREAMS = {
    RULE_THE_WORLD='rule the world', BRING_PEACE_TO_THE_WORLD='bring peace to the world',
    BECOME_A_LEGENDARY_WARRIOR='become a legendary warrior', FALL_IN_LOVE='fall in love',
    SEE_THE_GREAT_NATURAL_SITES='see the great natural sites', IMMORTALITY='live forever',
    MAKE_A_GREAT_DISCOVERY='make a great discovery', ATTAIN_RANK_IN_SOCIETY='rise in rank',
    BATHE_WORLD_IN_CHAOS='bathe the world in chaos',
}

-- Two facets picked at random from the four most extreme: enough to make a
-- dwarf distinct, and varied enough that every item a dwarf owns doesn't
-- show the same trait (the anxious duke paced in five of six).
local POOL_FACETS, SHOWN_FACETS = 4, 2

local function facet_phrases(traits)
    local strong = {}
    for i, v in ipairs(traits) do
        local phrases = FACETS[df.personality_facet_type[i]]
        if phrases and (v >= 76 or v <= 24) then
            table.insert(strong, {dist=math.abs(v - 50), v=v, phrases=phrases})
        end
    end
    table.sort(strong, function(a, b) return a.dist > b.dist end)
    local pool = {}
    for i = 1, math.min(POOL_FACETS, #strong) do pool[i] = strong[i] end
    local out = {}
    while #out < SHOWN_FACETS and #pool > 0 do
        local s = table.remove(pool, math.random(#pool))
        local phrase = s.v >= 76 and s.phrases[1] or s.phrases[2]
        -- "very anxious" reads fine; "very a peacemaker" doesn't
        if (s.v >= 91 or s.v <= 9) and not phrase:find(' ') then phrase = 'very ' .. phrase end
        table.insert(out, phrase)
    end
    return out
end

-- the single strongest value, if it's strongly held either way
local function value_phrase(values)
    local best
    for _, v in ipairs(values) do
        if VALUES[df.value_type[v.type]] and (not best or math.abs(v.strength) > math.abs(best.strength)) then
            best = v
        end
    end
    if not best or math.abs(best.strength) < 26 then return nil end
    local what = VALUES[df.value_type[best.type]]
    return best.strength > 0 and ('values ' .. what) or ('has no use for ' .. what)
end

-- "is fond of crowns" when the dwarf's likes include this item's type or
-- material; dwarves keep items they like, so this is often why they have it
local function matching_likes(unit, item, prefs)
    local out = {}
    for _, pr in ipairs(prefs) do
        local kind = df.unitpref_type[pr.type]
        if kind == 'LikeItem' and pr.item_type == item:getType()
                and (pr.item_subtype == -1 or pr.item_subtype == item:getSubtype()) then
            local count = 0
            for _, inv in ipairs(unit.inventory) do
                if inv.item:getType() == item:getType() then count = count + 1 end
            end
            local what = df.item_type[item:getType()]:lower():gsub('_', ' ')
            table.insert(out, count > 1 and ('is fond of this kind of item (%s) and carries %d of them'):format(what, count)
                    or ('is fond of this kind of item (%s)'):format(what))
        elseif kind == 'LikeMaterial' and pr.mattype == item:getActualMaterial()
                and pr.matindex == item:getActualMaterialIndex() then
            local mi = dfhack.matinfo.decode(pr.mattype, pr.matindex)
            table.insert(out, ('is especially fond of %s'):format(mi and dfhack.df2utf(mi:toString()) or 'its material'))
        end
    end
    return out
end

-- One line describing a dwarf, for someone who wears, carries or owns the
-- item. role is e.g. 'wearer' or 'owner'. Returns nil if there's nothing
-- notable to say. Dead dwarves (tomb owners) are described as they were.
function describe_person(unit, item, role)
    local soul = unit.status.current_soul
    if not soul then return nil end
    local p = soul.personality
    local parts = facet_phrases(p.traits)
    local value = value_phrase(p.values)
    if value then table.insert(parts, value) end
    for _, d in ipairs(p.dreams) do
        local dream = DREAMS[df.goal_type[d.type]]
        if dream then table.insert(parts, 'longs to ' .. dream); break end
    end
    for _, like in ipairs(matching_likes(unit, item, soul.preferences)) do table.insert(parts, like) end
    if #parts == 0 then return nil end
    local first = dfhack.df2utf(unit.name.first_name):gsub('^%l', string.upper)
    if dfhack.units.isDead(unit) then
        return ('About %s (the %s, now dead): in life, %s'):format(first, role, table.concat(parts, '; '))
    end
    return ('About %s (the %s): %s'):format(first, role, table.concat(parts, '; '))
end
