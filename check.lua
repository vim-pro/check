-- vim.pro check — CI for your editor.
--
-- Your code gets a test suite; your editor config gets pushed and prayed
-- over. This runs in your dotfiles repo — locally or as a GitHub Action —
-- and answers the question nothing in the ecosystem answers: does this
-- config actually BOOT on a machine that is not yours?
--
--   - finds your nvim config in the repo, whatever the layout (bare repo,
--     .config/nvim, chezmoi's dot_config, stow's aspects/…)
--   - provisions your declared plugins the way your manager expects them,
--     so the editor never wants the network
--   - boots it, headless, and reads what actually happened: startup time
--     from nvim's own clock (one settle boot first, then the median of
--     three warm ones), real init errors with their traces folded in,
--     what loaded
--   - fails the build when the editor fails, with the error quoted
--
-- Written in Lua and RUN BY NVIM ITSELF — the tool's only dependency is the
-- thing it tests, which is already installed or there is nothing to check.
-- The measured boots use vim.v.progpath, so the editor under test is exactly
-- the editor doing the testing. Needs nvim 0.10+ (vim.system).
--
-- The measurement matches vim.pro's worker (github.com/vim-pro/vim.pro),
-- which boots every connected config the same way — this is that measurement,
-- run where your pull requests live, against the commit being proposed.
--
-- Confinement note: the site's worker runs untrusted strangers' configs and
-- sandboxes accordingly. Here the config is YOURS and the machine is an
-- ephemeral CI runner (or your own), so the posture is lighter — but the
-- editor still gets a scrubbed env, no shell, and a hard timeout.
--
-- Usage:  nvim -l check.lua [repo-root]
--
-- DRIVER MODE. vim.pro's worker runs THIS FILE for its own boots — one
-- measurement, two callers, so a classifier or clock fix can never again land
-- in one place and not the other. The extra faculties the worker needs are
-- env hooks a CI user never sees:
--
--   VIMPRO_CHECK_JSON=1        append a VIMPRO_CHECK_RESULT {json} line
--   VIMPRO_CHECK_KEEP=1        keep the work tree (caller captures the
--                              portrait there, then cleans up)
--   VIMPRO_CHECK_ENTRY=path    trust the caller's entry, skip the walk
--   VIMPRO_CHECK_MANAGER=name  trust the caller's manager, skip the scout
--   VIMPRO_CHECK_PLUGINS=json  …and its plugin list (the site's real parser
--                              beats the scout)
--   VIMPRO_CHECK_ENV=json      extra env for the booted editor (a config
--                              that branches on $BASE16_THEME boots the way
--                              it boots at home)
--   VIMPRO_CHECK_UID=n         run the boots as this uid (the worker's
--                              namespace-free confinement; needs root)
--   VIMPRO_CHECK_SANDBOX=argv  prefix the boot argv (bwrap policy)

local uv = vim.uv

local TIMEOUT = tonumber(os.getenv('VIMPRO_CHECK_TIMEOUT_MS') or '') or 60000
-- fail-on: 'abort' (only a dead init fails) or 'error' (any init error fails)
local FAIL_ON = os.getenv('VIMPRO_CHECK_FAIL_ON') == 'abort' and 'abort' or 'error'

-- the driver hooks, read once
local DRIVER = {
  json = os.getenv('VIMPRO_CHECK_JSON') == '1',
  keep = os.getenv('VIMPRO_CHECK_KEEP') == '1',
  entry = os.getenv('VIMPRO_CHECK_ENTRY'),
  manager = os.getenv('VIMPRO_CHECK_MANAGER'),
  plugins = (function()
    local raw = os.getenv('VIMPRO_CHECK_PLUGINS')
    if not raw then return nil end
    local ok, v = pcall(vim.json.decode, raw)
    return ok and vim.islist(v) and v or nil
  end)(),
  env = (function()
    local raw = os.getenv('VIMPRO_CHECK_ENV')
    if not raw then return nil end
    local ok, v = pcall(vim.json.decode, raw)
    return ok and type(v) == 'table' and v or nil
  end)(),
  uid = tonumber(os.getenv('VIMPRO_CHECK_UID') or ''),
  sandbox = (function()
    local raw = (os.getenv('VIMPRO_CHECK_SANDBOX') or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' then return nil end
    return vim.split(raw, '%s+')
  end)(),
}

local function join(...) return table.concat({ ... }, '/') end
local function dirname(p) return p:match('^(.*)/[^/]*$') or '.' end
local function basename(p) return p:match('([^/]*)$') end
local function read_file(p)
  local f = io.open(p, 'r'); if not f then return nil end
  local t = f:read('*a'); f:close(); return t
end
local function write_file(p, text)
  local f = assert(io.open(p, 'w')); f:write(text); f:close()
end

-- ── find the config ────────────────────────────────────────────────────────
-- The entry file is init.lua/init.vim in a directory whose name ends in nvim —
-- which covers a bare config repo (the repo IS ~/.config/nvim, entry at the
-- top), .config/nvim, chezmoi's dot_config/nvim, and stow layouts like
-- aspects/nvim/.config/nvim. A vimrc at the repo root is the legacy shape and
-- boots via -u.
local function walk(root)
  local out = {}
  local function go(dir, depth)
    if depth > 6 then return end
    for name, kind in vim.fs.dir(dir) do
      if name ~= '.git' and name ~= 'node_modules' then
        local p = join(dir, name)
        if kind == 'directory' then go(p, depth + 1)
        else out[#out + 1] = p:sub(#root + 2) end
      end
    end
  end
  go(root, 0)
  return out
end

local function find_entry(paths)
  local inits = vim.tbl_filter(function(p)
    return p:match('^init%.lua$') or p:match('^init%.vim$')
      or p:match('/init%.lua$') or p:match('/init%.vim$')
  end, paths)
  local in_nvim_dir = vim.tbl_filter(function(p) return dirname(p):match('nvim$') end, inits)
  table.sort(in_nvim_dir, function(a, b) return #a < #b end)
  table.sort(inits, function(a, b) return #a < #b end)
  local bare
  for _, p in ipairs(inits) do if not p:find('/') then bare = p break end end
  local chosen = in_nvim_dir[1] or bare or inits[1]
  if chosen then return { entry = chosen, legacy = false } end
  for _, p in ipairs(paths) do
    if p:match('^%.?g?vimrc$') then return { entry = p, legacy = true } end
  end
  return nil
end

-- ── read the declarations, lightly ─────────────────────────────────────────
-- The site's parser is a real parser; this is a scout. It only has to find
-- enough to PROVISION — a plugin it misses shows up honestly in the boot
-- report as a module the editor could not find, rather than being silently
-- fine, so the failure direction is visible, not wrong.
local JUNK_OWNERS = {
  textDocument = true, tags = true, tests = true, plugin = true, plugins = true,
  lua = true, after = true, doc = true, custom = true, scripts = true,
}
local function scout_plugins(root, paths)
  local plugins, order = {}, {}
  local function add(name)
    if not plugins[name] then plugins[name] = true; order[#order + 1] = name end
  end
  local manager = nil
  local seen_lua = 0
  for _, p in ipairs(paths) do
    if p:match('%.lua$') and seen_lua < 200 then
      seen_lua = seen_lua + 1
      local text = read_file(join(root, p)) or ''
      if manager == nil and (text:find('lazypath', 1, true) or text:match([=[require%s*%(%s*['"]lazy['"]%s*%)]=])) then
        manager = 'lazy.nvim'
      end
      if text:match('vim%.pack%.add%f[%W]') then manager = 'vim.pack' end
      -- github URLs are unambiguous wherever they appear (quoted, as specs are)
      for name in text:gmatch([=[https://github%.com/([%w_%-%.]+/[%w_%-%.]+)['"]]=]) do
        add((name:gsub('%.git$', '')))
      end
      -- owner/repo strings from EVERY lua file. Gating on spec-looking paths
      -- missed lua/theprimeagen/lazy/ entirely, which left lazy to
      -- network-install thirty plugins inside the measured boot. Junk is
      -- filtered by shape instead: github owners cannot contain dots or
      -- underscores, path-fragment lookalikes (plugin/30_mini.lua,
      -- tests/screenshots) fail the owner or repo shape, and whatever
      -- survives wrongly just fails one bounded clone and lands in the
      -- unprovisioned warning, which is the visible direction.
      for name in text:gmatch([=[['"]([%w][%w%-]*/[%w][%w_%.%-]*)['"]]=]) do
        local owner, repo = name:match('^(.-)/(.*)$')
        local junk = JUNK_OWNERS[owner] or owner:find('_')
          or repo:match('^%d')
          or (repo:find('%.') and not (repo:match('%.nvim$') or repo:match('%.vim$')))
        if not junk then add(name) end
      end
      for name in text:gmatch([=[Plug%s+['"]([%w_%.%-]+/[%w_%.%-]+)['"]]=]) do
        add(name); manager = manager or 'vim-plug'
      end
    end
  end
  local gm = read_file(join(root, '.gitmodules'))
  if gm and ('\n' .. gm):match('[\n/]pack/[^/\n]+/start/') or gm and ('\n' .. gm):match('[\n/]pack/[^/\n]+/opt/') then
    manager = manager or 'native packages'
  end
  return { manager = manager, plugins = order }
end

-- ── provisioning (the same layout vim.pro's worker provisions) ─────────────
local function provision_plan(manager, plugins, data_dir)
  local std = join(data_dir, 'nvim')   -- stdpath('data') is $XDG_DATA_HOME/nvim
  local plan = {}
  -- 'a plugin spec' is the site parser's name for a lazy-shaped spec dir
  if manager == 'lazy.nvim' or manager == 'a plugin spec' then
    plan[#plan + 1] = { name = 'folke/lazy.nvim', dest = join(std, 'lazy', 'lazy.nvim') }
    for _, p in ipairs(plugins) do plan[#plan + 1] = { name = p, dest = join(std, 'lazy', basename(p)) } end
  elseif manager == 'vim.pack' then
    for _, p in ipairs(plugins) do
      plan[#plan + 1] = { name = p, dest = join(std, 'site', 'pack', 'core', 'opt', basename(p)) }
    end
  end
  -- native packages ride the repo's own submodules; unknown managers provision nothing
  return plan
end

local function git(args, opts)
  opts = opts or {}
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  return vim.system(cmd, {
    cwd = opts.cwd, timeout = opts.timeout_ms or 120000,
    env = { GIT_TERMINAL_PROMPT = '0' },   -- merged over the parent env
  }):wait()
end

-- ── stderr classification (the worker's rules) ─────────────────────────────
-- One error is one error, however many lines its trace takes; download chatter
-- is a notice, never an error.
local function is_error_start(line)
  return line:match('^E%d') or line:match('E%d+:') or line:match('^Error')
    or line:match('^error:') or line:match('Error detected')
    or line:match('^Failed ') or line:match('^fatal:') or false
end
local function is_continuation(line)
  return line:match('^%s') or line:match('^no file ') or line:match('^no field ')
    or line:match('^%[C%]:') or line:match('^stack traceback') or line:match('^%.%.%.')
    or line:match('^\t') or false
end
local function classify_stderr(text)
  local errors, notices = {}, {}
  local in_error = false
  for raw in (tostring(text or '') .. '\n'):gmatch('(.-)\n') do
    local line = raw:gsub('%s+$', '')
    local trimmed = line:gsub('^%s+', '')
    if trimmed ~= '' and not trimmed:match('^vim%.pack: Repaired corrupted lock data') then
      -- an error line ending in ':' has said WHERE but not WHAT — the next
      -- line is its message body whatever its shape ('No specs found for
      -- module …' matches none of the continuation forms, and losing the body
      -- turns a diagnosable failure into 'Error in init.lua:' full stop)
      local owed = in_error and #errors > 0 and errors[#errors]:match(':$')
      if (is_continuation(line) or (owed and not is_error_start(trimmed)))
        and ((in_error and #errors > 0) or (not in_error and #notices > 0)) then
        if in_error and #errors > 0 then
          local _, folds = errors[#errors]:gsub('\n', '')
          if folds < 2 then errors[#errors] = errors[#errors] .. '\n' .. trimmed end
        end
      elseif is_error_start(trimmed) then
        errors[#errors + 1] = trimmed; in_error = true
      else
        notices[#notices + 1] = trimmed; in_error = false
      end
    end
  end
  return { errors = vim.list_slice(errors, 1, 12), notices = vim.list_slice(notices, 1, 30) }
end

local DUMP_LUA = [[
local out = {}
-- built from fields: tostring(vim.version()) yields "0.12.4+v0.12.4", the
-- version followed by its own build tag, which reads as a typo on a page
local _v = vim.version()
out.nvim = string.format('%d.%d.%d', _v.major, _v.minor, _v.patch)
local maps = 0
for _, m in ipairs({ 'n', 'v', 'x', 's', 'o', 'i', 'c', 't' }) do
  maps = maps + #vim.api.nvim_get_keymap(m)
end
out.mappings = maps
out.rtp_missing = {}
local loaded = {}
-- EXPANDED paths for what loaded: 'runtimepath' entries may be globs
-- (pack/*/start/* is a real idiom), and nvim_list_runtime_paths is the
-- expanded view. The raw option is still the right place to look for entries
-- that point NOWHERE, since a glob that matches nothing simply vanishes from
-- the expansion.
for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
  local name = p:match('/pack/[^/]+/[^/]+/([^/]+)/?$') or p:match('/lazy/([^/]+)/?$')
  if name and name ~= 'lazy.nvim' then loaded[name] = true end
end
for _, p in ipairs(vim.opt.runtimepath:get()) do
  if p:find('[*?]') then
    if #vim.fn.glob(p, true, true) == 0 then table.insert(out.rtp_missing, p) end
  elseif vim.fn.isdirectory(p) == 0 then
    table.insert(out.rtp_missing, p)
  end
end
out.plugins_loaded = vim.fn.sort(vim.tbl_keys(loaded))
-- the messages a person would see on a real start — deprecation warnings,
-- notify()s from plugins, the tail of anything that went wrong quietly
local msg = vim.api.nvim_exec2('messages', { output = true }).output or ''
if #msg > 2000 then msg = msg:sub(-2000) end
out.messages = msg
io.stdout:write('\nVIMPRO_CHECK ' .. vim.json.encode(out) .. '\n')
]]

-- ── running a boot ─────────────────────────────────────────────────────────
-- vim.system, minus two things it cannot do: drop the child to another uid
-- (the worker's namespace-free confinement) and prefix the argv (its bwrap
-- policy). Used for EVERY measured boot, driver mode or not, so the CI
-- fixtures exercise the same code path production runs. env REPLACES the
-- child's environment entirely — the scrub is by construction.
local function run_process(argv, opts)
  local stdout_p, stderr_p = uv.new_pipe(false), uv.new_pipe(false)
  local out, err = {}, {}
  local done, eof_out, eof_err = false, false, false
  local code_, signal_
  local envlist = {}
  for k, v in pairs(opts.env or {}) do envlist[#envlist + 1] = k .. '=' .. tostring(v) end
  local handle
  handle = uv.spawn(argv[1], {
    args = vim.list_slice(argv, 2),
    stdio = { nil, stdout_p, stderr_p },
    env = envlist,
    uid = opts.uid, gid = opts.uid,
  }, function(code, signal)
    code_, signal_ = code, signal
    done = true
    if handle and not handle:is_closing() then handle:close() end
  end)
  if not handle then
    stdout_p:close(); stderr_p:close()
    return { spawn_failed = true, code = -1, signal = 0, stdout = '', stderr = '' }
  end
  stdout_p:read_start(function(_, chunk)
    if chunk then out[#out + 1] = chunk else eof_out = true end
  end)
  stderr_p:read_start(function(_, chunk)
    if chunk then err[#err + 1] = chunk else eof_err = true end
  end)
  -- wait for exit AND both pipes' EOF — the exit callback can fire before the
  -- last chunks arrive, and a truncated stdout would lose the dump marker
  local finished = vim.wait(opts.timeout or 60000, function()
    return done and eof_out and eof_err
  end, 10)
  if not finished then
    if handle and not handle:is_closing() then pcall(handle.kill, handle, 'sigkill') end
    vim.wait(2000, function() return done end, 10)
    stdout_p:close(); stderr_p:close()
    return { timed_out = true, code = code_, signal = signal_ or 9,
      stdout = table.concat(out), stderr = table.concat(err) }
  end
  stdout_p:close(); stderr_p:close()
  return { code = code_, signal = signal_ or 0, stdout = table.concat(out), stderr = table.concat(err) }
end

-- ── the check ──────────────────────────────────────────────────────────────
local function run_check(root)
  root = uv.fs_realpath(root or '.') or root
  local paths = walk(root)
  -- legacy = a bare vimrc name (dot and g optional), at root or under a dir —
  -- suffix-matching alone would call 'myvimrc' legacy, which the walk never
  -- produces but a driver-supplied entry could
  local found = DRIVER.entry and { entry = DRIVER.entry,
    legacy = ((DRIVER.entry:match('^%.?g?vimrc$') or DRIVER.entry:match('/%.?g?vimrc$'))
      and not DRIVER.entry:match('init%.[lv][ui][am]$')) and true or false }
    or find_entry(paths)
  if not found then return { skip = 'no vim config found in this repository' } end
  local entry, legacy = found.entry, found.legacy

  -- driver mode trusts its caller: the site's parser already identified the
  -- entry and read the declarations properly, and the scout must not overrule
  -- a real parser (or drag in plugins the parser deliberately excluded)
  local scout
  if DRIVER.manager ~= nil or DRIVER.plugins ~= nil then
    scout = { manager = DRIVER.manager, plugins = DRIVER.plugins or {} }
  else
    scout = scout_plugins(root, paths)
  end
  local work = assert(uv.fs_mkdtemp(join(os.getenv('TMPDIR') or '/tmp', 'vimpro-check-XXXXXX')))
  local ok, res = pcall(function()
    local xdg_config = join(work, 'config')
    vim.fn.mkdir(xdg_config, 'p')
    if not legacy then uv.fs_symlink(join(root, dirname(entry)), join(xdg_config, 'nvim')) end

    -- native packages: make sure the config dir's submodules are actually
    -- present — on a fresh CI checkout they are not, unless the workflow asked
    -- for them. Shallow first, full on failure, https whatever .gitmodules says.
    if uv.fs_stat(join(root, '.gitmodules')) and not legacy then
      local function sub(extra)
        local args = { '-c', 'url.https://github.com/.insteadOf=git@github.com:',
          '-C', root, 'submodule', 'update', '--init', '--jobs', '4' }
        vim.list_extend(args, extra)
        vim.list_extend(args, { '--', dirname(entry) })
        return git(args, { timeout_ms = 180000 })
      end
      local sm = sub({ '--depth', '1' })
      if sm.code ~= 0 then sub({}) end
      -- a submodule that still fails will show up in the boot as a missing
      -- module, which is the honest place for it
    end

    local data_dir = join(work, 'data')
    local provisioned, unprovisioned = {}, {}
    local seen = {}
    for _, item in ipairs(provision_plan(scout.manager, scout.plugins, data_dir)) do
      -- one destination, one clone: the scout finds folke/lazy.nvim in the
      -- bootstrap AND the plan prepends it, and the second clone into the
      -- same non-empty directory failed as a spurious warning on every
      -- single lazy config in the corpus
      if not seen[item.dest] then
        seen[item.dest] = true
        if not item.name:match('^[%w_%.%-]+/[%w_%.%-]+$') then
          unprovisioned[#unprovisioned + 1] = item.name
        else
          vim.fn.mkdir(dirname(item.dest), 'p')
          local r = git({ 'clone', '--quiet', '--depth', '1', '--no-tags', '--recurse-submodules=no',
            'https://github.com/' .. item.name .. '.git', item.dest }, { timeout_ms = 60000 })
          if r.code == 0 then provisioned[#provisioned + 1] = item.name
          else unprovisioned[#unprovisioned + 1] = item.name end
        end
      end
    end

    local dump = join(work, 'dump.lua')
    write_file(dump, DUMP_LUA)
    local st_file = join(work, 'startuptime.log')
    -- the editor under test is EXACTLY the editor running this script
    local nvim_args = { vim.v.progpath, '--headless', '-n', '-i', 'NONE', '--startuptime', st_file,
      '--cmd', 'set shell=/bin/false shellcmdflag=' }
    if legacy then vim.list_extend(nvim_args, { '-u', join(root, entry) }) end
    vim.list_extend(nvim_args, { '-c', 'luafile ' .. dump, '-c', 'qa!' })

    -- the sandbox policy wraps the argv; the work tree is the one dynamic bind
    local argv = {}
    if DRIVER.sandbox then
      vim.list_extend(argv, DRIVER.sandbox)
      vim.list_extend(argv, { '--bind', work, work })
    end
    vim.list_extend(argv, nvim_args)

    local boot_env = {
      PATH = os.getenv('PATH'), HOME = work, TMPDIR = work, TERM = 'dumb', LANG = 'C.UTF-8',
      XDG_CONFIG_HOME = xdg_config, XDG_DATA_HOME = data_dir,
      XDG_STATE_HOME = join(work, 'state'), XDG_CACHE_HOME = join(work, 'cache'),
    }
    -- the config's OWN environment, resolved from its own dotfiles by the
    -- caller (schemeenv) — it should boot the way it boots at home
    for k, v in pairs(DRIVER.env or {}) do boot_env[k] = v end

    -- the dropped uid must be able to read the config and write the scratch
    if DRIVER.uid then
      local function chown_tree(path)
        pcall(uv.fs_chown, path, DRIVER.uid, DRIVER.uid)
        local st = uv.fs_stat(path)
        if st and st.type == 'directory' then
          for name in vim.fs.dir(path) do chown_tree(join(path, name)) end
        end
      end
      chown_tree(work)
    end

    local function boot()
      return run_process(argv, { env = boot_env, uid = DRIVER.uid, timeout = TIMEOUT })
    end
    local function boot_ms()
      local log = read_file(st_file)
      if not log then return nil end
      local last = log:gsub('%s+$', ''):match('([^\n]*)$')
      local t = last and last:match('^([%d%.]+)')
      return t and math.floor(tonumber(t) + 0.5) or nil
    end

    -- THE FIRST BOOT IS SETUP, NOT THE MEASUREMENT. A config legitimately does
    -- one-time work on a fresh machine — fetching locked revisions, compiling
    -- parsers, downloading a plugin's binary — and ThePrimeagen's "29-second
    -- startup" in the corpus was mostly that. Boot once to let it settle (the
    -- cost is reported separately), then measure the boots that describe every
    -- day after, and take their median — one warm sample still wobbles.
    local r = boot()
    if r.timed_out or r.spawn_failed or r.signal ~= 0 then
      return { entry = entry, manager = scout.manager, provisioned = provisioned,
        unprovisioned = unprovisioned, aborted = true,
        errors = { r.spawn_failed and 'the editor could not be started'
          or 'the editor did not finish booting within ' .. math.floor(TIMEOUT / 1000 + 0.5) .. 's' },
        notices = {} }
    end
    local first_ms = boot_ms()
    -- a dead init fails identically warm — report the boot that failed
    local first_aborted = false
    for _, e in ipairs(classify_stderr(r.stderr).errors) do
      if e:match('E5113') or e:match('Error detected while processing') or e:match('E5108') then
        first_aborted = true
      end
    end
    local ms = first_ms
    if not first_aborted then
      local warm = {}
      for _ = 1, 3 do
        local w = boot()
        if w.timed_out or w.spawn_failed or w.signal ~= 0 then break end   -- keep what we have
        warm[#warm + 1] = { r = w, ms = boot_ms() }
      end
      local timed = {}
      for _, w in ipairs(warm) do if w.ms then timed[#timed + 1] = w.ms end end
      if #warm > 0 then r = warm[#warm].r end   -- steady state speaks
      if #timed > 0 then
        table.sort(timed)
        ms = timed[math.floor((#timed - 1) / 2) + 1]
      end
    end

    -- both spellings of both roots: macOS reports /private/var for paths that
    -- mkdtemp handed us as /var, and a half-scrubbed path reads as gibberish
    local scrubbed = r.stderr or ''
    for _, base in ipairs({ root, work }) do
      for _, variant in ipairs({ base, uv.fs_realpath(base) or base, '/private' .. base }) do
        scrubbed = scrubbed:gsub(vim.pesc(variant .. '/'), '')
      end
    end
    if os.getenv('VIMPRO_CHECK_DEBUG') then
      io.stderr:write('── raw stderr ──\n' .. scrubbed .. '\n── end raw ──\n')
    end
    local classified = classify_stderr(scrubbed)
    local aborted = false
    for _, e in ipairs(classified.errors) do
      if e:match('^E5113') or e:match('Error detected while processing') or e:match('^E5108') then
        aborted = true
      end
    end
    local marker = (r.stdout or ''):match('.*VIMPRO_CHECK ([^\n]*)')
    local ok_dump, dumped = pcall(vim.json.decode, marker or '')
    if not ok_dump then dumped = nil end

    local scrub = function(text)
      local t = tostring(text or '')
      for _, base in ipairs({ root, work }) do
        for _, variant in ipairs({ base, uv.fs_realpath(base) or base, '/private' .. base }) do
          t = t:gsub(vim.pesc(variant .. '/'), ''):gsub(vim.pesc(variant), '')
        end
      end
      return t
    end
    return {
      entry = entry, legacy = legacy, manager = scout.manager,
      nvim = dumped and dumped.nvim or nil, ms = ms, first_ms = first_ms, aborted = aborted,
      errors = classified.errors, notices = classified.notices,
      plugins_loaded = dumped and dumped.plugins_loaded or {},
      -- driver-mode extras; empty tables cost a CI user nothing
      mappings = dumped and dumped.mappings or nil,
      rtp_missing = dumped and dumped.rtp_missing or {},
      messages = dumped and scrub(dumped.messages) or '',
      provisioned = provisioned, unprovisioned = unprovisioned,
      -- the kept tree, so the caller can capture a portrait from EXACTLY the
      -- editor the numbers describe, then clean up
      work = DRIVER.keep and work or nil,
      xdg_config = DRIVER.keep and xdg_config or nil,
      data_dir = DRIVER.keep and data_dir or nil,
    }
  end)
  if not (ok and DRIVER.keep) then pcall(vim.fs.rm, work, { recursive = true, force = true }) end
  if not ok then error(res, 0) end
  return res
end

-- ── report ─────────────────────────────────────────────────────────────────
local function plural(n) return n == 1 and '' or 's' end
local function summarize(res)
  if res.skip then return { ok = true, lines = { 'vim.pro check: skipped — ' .. res.skip } } end
  local lines = {}
  lines[#lines + 1] = 'vim.pro check · ' .. res.entry
    .. (res.manager and (' · plugins via ' .. res.manager) or '')
  if #res.provisioned > 0 then
    lines[#lines + 1] = ('  provisioned %d plugin%s for the boot'):format(#res.provisioned, plural(#res.provisioned))
  end
  if #res.unprovisioned > 0 then
    lines[#lines + 1] = '  ⚠ could not provision: ' .. table.concat(res.unprovisioned, ', ')
  end
  if res.aborted then
    lines[#lines + 1] = '  ✕ FAILS TO BOOT on a clean machine — init aborted'
  elseif #res.errors > 0 then
    lines[#lines + 1] = ('  ✕ boots with %d error%s (%sms on nvim %s)')
      :format(#res.errors, plural(#res.errors), tostring(res.ms), tostring(res.nvim))
  else
    lines[#lines + 1] = ('  ▲ boots clean in %sms on nvim %s · %d plugins load')
      :format(tostring(res.ms), tostring(res.nvim), #res.plugins_loaded)
    -- one-time setup that dwarfs the steady state is worth a line of its own
    if res.first_ms and res.ms and res.first_ms > 2 * res.ms + 500 then
      lines[#lines + 1] = ('    first boot %dms — one-time setup, not counted'):format(res.first_ms)
    end
  end
  for _, e in ipairs(res.errors or {}) do
    lines[#lines + 1] = '    ' .. e:gsub('\n', '\n    ')
  end
  local failed = res.aborted or (FAIL_ON == 'error' and #(res.errors or {}) > 0)
  return { ok = not failed, lines = lines }
end

-- ── main ───────────────────────────────────────────────────────────────────
-- `--classify` reads stderr on stdin and prints the classification as JSON:
-- the seam that lets vim.pro's test suite exercise THESE rules, not a copy.
if _G.arg and _G.arg[1] == '--classify' then
  local text = io.read('*a') or ''
  io.stdout:write(vim.json.encode(classify_stderr(text)) .. '\n')
  os.exit(0)
end

local res = run_check(_G.arg and _G.arg[1] or '.')
local sum = summarize(res)
io.stdout:write(table.concat(sum.lines, '\n') .. '\n')
if DRIVER.json then
  io.stdout:write('VIMPRO_CHECK_RESULT ' .. vim.json.encode(res) .. '\n')
end
-- GitHub annotations + job summary, when running as an Action
local step_summary = os.getenv('GITHUB_STEP_SUMMARY')
if step_summary then
  local md = { '### vim.pro check', '' }
  for _, l in ipairs(sum.lines) do
    local t = l:gsub('^%s+', ''):gsub('%s+$', '')
    md[#md + 1] = t ~= '' and ('- ' .. t) or ''
  end
  local f = io.open(step_summary, 'a')
  if f then f:write(table.concat(md, '\n') .. '\n'); f:close() end
end
if not sum.ok then
  for _, e in ipairs(res.errors or {}) do
    io.stdout:write('::error title=vim.pro check::'
      .. e:gsub('%%', '%%25'):gsub('\n', '%%0A') .. '\n')
  end
  os.exit(1)
end
