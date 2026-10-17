-- Config, non-blocking HTTP client, and LLM API adapters for llm-lore.
--
-- DFHack's Lua has no os.execute/io.popen, so HTTP goes through the
-- luasocket plugin. Requests are sent and then polled every few frames, so
-- the game keeps running while the model writes.
--@ module = true

local json = require('json')
local luasocket = require('plugins.luasocket')

MOD_ID = 'llm_lore'

DEFAULT_CONFIG = {
    -- 'ollama' (native /api/chat) or 'openai' (any /v1/chat/completions server:
    -- llama.cpp, LM Studio, vLLM, Ollama's compat endpoint, ...)
    api='ollama',
    -- use an IP address: DFHack's socket plugin can't resolve mDNS (.local) names
    url='http://192.168.1.30:11434',
    model='gemma3:12b',
    api_key='',
    temperature=0.8,
    max_tokens=220,
    timeout_seconds=120,
    -- generate automatically when an item sheet is opened
    auto_generate=true,
    -- rewrite a description when the item changes hands, moves, or wears
    rewrite_on_change=true,
    -- only describe artifacts and built/crafted items (not boulders, bars, ...)
    only_constructed=true,
    -- tuned against devel/llm-lore-eval; see README "Prompt notes"
    system_prompt=table.concat({
        'You are the chronicler of a dwarven fortress in the world of Dwarf Fortress.',
        'Given facts about one item, describe it as it exists right now in the daily life of the fortress. Lead with the focus given in the facts and keep to the length given. Favour the concrete and lived-in over the grand; it is not an exhibit or a museum piece.',
        '',
        'Rules:',
        '- The only dwarves who may appear are the ones named in the facts, doing only what the facts say. If no one is holding or using the item, it is at rest: do not introduce any particular dwarf. General mentions of fortress life (diners, soldiers, drinkers) are fine.',
        '- The maker made the item in the past; do not show the maker handling it now.',
        '- Use pronouns matching each dwarf\'s sex.',
        '- When a dwarf\'s personality is given, let it shape how they treat or feel about the item. Invented feelings and habits are welcome if they follow from the facts; never ones that contradict them.',
        '- Match the item\'s condition. An item in good repair is clean and cared for; do not give it dust, scratches, chips or grime.',
        '- Avoid the stock details: haulers bumping or passing it, dust settling, smells lingering, \'faint\' anything. Use one only if it is truly the most telling detail for this item.',
        '- Do not end sentences with explanatory tags such as \'a reminder of...\', \'evidence of...\' or \'a souvenir of...\'.',
        '- Never invent images, carvings or maker\'s marks, never say what an image depicts unless the facts say so, and never invent magic, materials or decorations.',
        '- Never invent specific events such as raids, battles, cave-ins, deaths, burials or injuries. For written works, draw on the title, genre, author and subjects given.',
        '- Never invent where an item is, or what else is in its stockpile or bin, beyond the facts.',
        '- Never use the word \'testament\' or the phrase \'speaks of\'.',
        '- Write plain prose only: no title, no markdown, no surrounding quotes.',
        '',
        'Example facts:',
        'Item: granite table / Material: granite / Quality: finely-crafted / Condition: in good repair, no wear / Made by (in the past): Ast Lolor, female / Installed in the fortress as a table / Located in a dining hall, where dwarves eat their meals / No one is holding or using it at the moment / Focus: how it is used in the fortress day to day / Length: two or three sentences, under 70 words.',
        'Example description:',
        'At mealtimes the granite table vanishes under bowls, mugs and elbows, and the talk around it rarely stops; between meals it is wiped down and left bare. Ast Lolor squared its edges true, and the grey stone has taken a soft shine from plates sliding across it.',
    }, '\n'),
}

-- script-manager.getModStatePath() would be the natural choice, but in DFHack
-- 53.16 it concatenates strings with '+' and errors out.
function get_state_dir()
    local path = ('%s/mods/%s/'):format(dfhack.getConfigPath(), MOD_ID)
    if not dfhack.filesystem.mkdir_recursive(path) then
        error(('failed to create mod state directory: "%s"'):format(path))
    end
    return path
end

function get_config_path()
    return get_state_dir() .. 'config.json'
end

-- Reads the user's config, filling in defaults for missing keys. Writes the
-- defaults out on first use so there is a file to edit.
function load_config()
    local path = get_config_path()
    local cfg = copyall(DEFAULT_CONFIG)
    if not dfhack.filesystem.exists(path) then
        json.encode_file(cfg, path)
        return cfg
    end
    local ok, user = pcall(json.decode_file, path)
    if not ok or type(user) ~= 'table' then
        dfhack.printerr(('llm-lore: could not parse %s; using defaults'):format(path))
        return cfg
    end
    for k, v in pairs(user) do cfg[k] = v end
    return cfg
end

---------------------------------------------------------------------------
-- async HTTP
--
-- The response is read one byte at a time inside pcall: with 1-byte reads
-- nothing can be lost, and "would block" just means "nothing yet". EOF can't
-- be told apart from "nothing yet" (clsocket reports a stale errno), so we
-- rely on Content-Length or the chunked-encoding terminator instead.

local MAX_READ_PER_POLL = 64 * 1024
local POLL_FRAMES = 5

-- id -> {sock=, buf={}, deadline=, cb=}
jobs = jobs or {}
local next_job_id = 0
local polling = false

local function parse_url(url)
    local scheme, host, port, path = url:match('^(%a+)://([^:/]+):?(%d*)(.*)$')
    if scheme ~= 'http' then
        error('only http:// URLs are supported, got: ' .. tostring(url))
    end
    return host, tonumber(port) or 80, path ~= '' and path or '/'
end

-- returns the decoded body, or nil if the chunked body is incomplete
local function dechunk(body)
    local out, pos = {}, 1
    while true do
        local size_hex, data_start = body:match('^(%x+)[^\r\n]*\r\n()', pos)
        if not size_hex then return nil end
        local size = tonumber(size_hex, 16)
        if size == 0 then return table.concat(out) end
        if #body < data_start + size + 1 then return nil end
        table.insert(out, body:sub(data_start, data_start + size - 1))
        pos = data_start + size + 2
    end
end

-- returns nil while incomplete; otherwise (body, err)
local function parse_response(data)
    local head_end = data:find('\r\n\r\n', 1, true)
    if not head_end then return nil end
    local head = data:sub(1, head_end + 1):lower()
    local body = data:sub(head_end + 4)
    local len = tonumber(head:match('\r\ncontent%-length:%s*(%d+)'))
    if len then
        if #body < len then return nil end
        body = body:sub(1, len)
    elseif head:find('\r\ntransfer%-encoding:%s*chunked') then
        body = dechunk(body)
        if not body then return nil end
    else
        return nil -- no way to know when it ends; wait for the deadline
    end
    local code = tonumber(head:match('^http/[%d.]+ (%d%d%d)'))
    if not code then return false, 'malformed HTTP response' end
    if code < 200 or code >= 300 then
        return false, ('HTTP %d: %s'):format(code, body)
    end
    return body
end

local function close_job(id, job)
    jobs[id] = nil
    pcall(job.sock.close, job.sock)
end

local function finish_job(job, body, err)
    local ok, cb_err = pcall(job.cb, body or nil, err)
    if not ok then dfhack.printerr('llm-lore: callback error: ' .. tostring(cb_err)) end
end

-- reads whatever has arrived; returns an error message if the socket failed
local function read_available(job)
    for _ = 1, MAX_READ_PER_POLL do
        local ok, res = pcall(job.sock.receive, job.sock, 1)
        if not ok then
            local msg = tostring(res)
            if msg:find('would block', 1, true) or msg:find('No socket error', 1, true) then
                return
            end
            return msg
        end
        if not res then return end
        table.insert(job.buf, res)
        job.dirty = true
    end
end

local ensure_polling

-- Scans every job, then runs callbacks for the finished ones. Callbacks run
-- after the scan because they often start new requests, and adding to `jobs`
-- while iterating it with pairs() is an error in Lua.
local function scan_jobs()
    local finished = {}
    for id, job in pairs(jobs) do
        local err = read_available(job)
        if err and #job.buf > 0 then
            -- the server closing the connection can surface as a bogus error
            -- (clsocket reports a stale errno), so see if the response is
            -- already complete before failing
            local body, perr = parse_response(table.concat(job.buf))
            if body ~= nil then
                table.insert(finished, {id=id, job=job, body=body, err=perr})
            else
                table.insert(finished, {id=id, job=job, err=err})
            end
        elseif err then
            table.insert(finished, {id=id, job=job, err=err})
        elseif job.dirty then
            job.dirty = false
            job.buf = {table.concat(job.buf)}
            local body, perr = parse_response(job.buf[1])
            if body ~= nil then
                table.insert(finished, {id=id, job=job, body=body, err=perr})
            end
        end
        if #finished == 0 or finished[#finished].id ~= id then
            if os.time() > job.deadline then
                table.insert(finished, {id=id, job=job, err='request timed out'})
            end
        end
    end
    for _, f in ipairs(finished) do close_job(f.id, f.job) end
    for _, f in ipairs(finished) do finish_job(f.job, f.body, f.err) end
end

local function poll()
    polling = false
    local ok, err = pcall(scan_jobs)
    if not ok then dfhack.printerr('llm-lore: poll error: ' .. tostring(err)) end
    ensure_polling()
end

ensure_polling = function()
    if polling or not next(jobs) then return end
    polling = true
    dfhack.timeout(POLL_FRAMES, 'frames', poll)
end

function num_pending()
    local n = 0
    for _ in pairs(jobs) do n = n + 1 end
    return n
end

-- POSTs a JSON body to url. Connecting blocks briefly (fine on a LAN); the
-- response is collected in the background and cb(body_string, err) is called
-- later from the main thread.
function post_json(cfg, url, body, headers, cb)
    local ok, err = pcall(function()
        local host, port, path = parse_url(url)
        local payload = json.encode(body)
        local lines = {
            ('POST %s HTTP/1.1'):format(path),
            ('Host: %s:%d'):format(host, port),
            'Content-Type: application/json',
            ('Content-Length: %d'):format(#payload),
            'Connection: close',
        }
        for _, h in ipairs(headers or {}) do table.insert(lines, h) end
        local sock = luasocket.tcp:connect(host, port)
        sock:send(table.concat(lines, '\r\n') .. '\r\n\r\n' .. payload)
        next_job_id = next_job_id + 1
        jobs[next_job_id] = {sock=sock, buf={}, deadline=os.time() + cfg.timeout_seconds, cb=cb}
    end)
    if not ok then
        return cb(nil, ('could not reach %s: %s'):format(url, tostring(err)))
    end
    ensure_polling()
end

-- after a script reload, pick up any requests left over from the old code
ensure_polling()

---------------------------------------------------------------------------
-- LLM APIs

local function clean_response(text)
    text = text:gsub('<think>.-</think>', '')   -- reasoning models (qwen3, deepseek)
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    text = text:gsub('^"(.*)"$', '%1')
    return text
end

-- messages: list of {role=, content=} (UTF-8). cb(text, err).
function chat(cfg, messages, cb)
    local base = cfg.url:gsub('/+$', '')
    local url, body, headers
    if cfg.api == 'openai' then
        url = base .. '/v1/chat/completions'
        body = {model=cfg.model, messages=messages, stream=false,
                temperature=cfg.temperature, max_tokens=cfg.max_tokens}
        if cfg.api_key and #cfg.api_key > 0 then
            headers = {'Authorization: Bearer ' .. cfg.api_key}
        end
    else
        url = base .. '/api/chat'
        body = {model=cfg.model, messages=messages, stream=false, keep_alive='30m',
                options={temperature=cfg.temperature, num_predict=cfg.max_tokens}}
    end

    post_json(cfg, url, body, headers, function(raw, err)
        if err then return cb(nil, err) end
        local ok, resp = pcall(json.decode, raw)
        if not ok or type(resp) ~= 'table' then
            return cb(nil, 'could not parse response: ' .. tostring(raw))
        end
        if resp.error then
            return cb(nil, type(resp.error) == 'table' and resp.error.message or tostring(resp.error))
        end
        local text
        if cfg.api == 'openai' then
            text = resp.choices and resp.choices[1] and resp.choices[1].message
                    and resp.choices[1].message.content
        else
            text = resp.message and resp.message.content
        end
        if type(text) ~= 'string' or #text == 0 then
            return cb(nil, 'empty response: ' .. tostring(raw))
        end
        cb(clean_response(text))
    end)
end
