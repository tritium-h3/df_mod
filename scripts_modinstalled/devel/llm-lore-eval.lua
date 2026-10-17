-- Generates descriptions for a set of items under several prompt variants and
-- writes them to a JSON file for side-by-side review. Nothing is saved to the
-- world.
--
-- Usage: devel/llm-lore-eval <spec.json>
--
-- spec.json:
--   {
--     "items": [27616, 45342, ...],
--     "variants": [            -- "no_retry": true skips the invented-name retry
--       {"name": "baseline", "include_usage": false},
--       {"name": "in-use", "system_prompt": "..."}
--     ],
--     "out": "/path/to/results.json"
--   }
-- A variant without system_prompt uses the configured one.

local json = require('json')
local lore = reqscript('llm-lore')
local backend = reqscript('internal/llm-lore/backend')

local spec_path = ...
if not spec_path then qerror('usage: devel/llm-lore-eval <spec.json>') end
local spec = json.decode_file(spec_path)

local queue = {}
for _, variant in ipairs(spec.variants) do
    for _, id in ipairs(spec.items) do
        local item = df.item.find(id)
        if item then
            table.insert(queue, {variant=variant, item=item})
        else
            dfhack.printerr(('llm-lore-eval: no item %d'):format(id))
        end
    end
end

local base_cfg = lore.get_config()
local results = {}
local started = os.time()

local function write_results(done)
    json.encode_file({done=done, total=#queue, model=base_cfg.model,
            elapsed_seconds=os.time() - started, results=results}, spec.out)
end

local function run(i)
    if i > #queue then
        write_results(true)
        print(('llm-lore-eval: wrote %d results to %s'):format(#results, spec.out))
        return
    end
    local job = queue[i]
    local t0 = os.time()
    local opts = {system_prompt=job.variant.system_prompt, include_usage=job.variant.include_usage,
                  include_people=job.variant.include_people, focus=job.variant.focus}
    local describe = job.variant.no_retry and function(item, o, cb)
        local messages = lore.build_messages(item, o)
        backend.chat(base_cfg, messages, function(text, err) cb(text, err, messages) end)
    end or lore.describe
    describe(job.item, opts, function(text, err, messages)
        table.insert(results, {
            id=job.item.id,
            variant=job.variant.name,
            model=base_cfg.model,
            seconds=os.time() - t0,
            facts=messages[2].content,
            text=text,
            error=err,
        })
        write_results(false)
        run(i + 1)
    end)
end

print(('llm-lore-eval: %d requests queued'):format(#queue))
run(1)
