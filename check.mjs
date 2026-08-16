#!/usr/bin/env node
// vim.pro check — CI for your editor.
//
// Your code gets a test suite; your editor config gets pushed and prayed
// over. This runs in your dotfiles repo — locally or as a GitHub Action —
// and answers the question nothing in the ecosystem answers: does this
// config actually BOOT on a machine that is not yours?
//
//   - finds your nvim config in the repo, whatever the layout (bare repo,
//     .config/nvim, chezmoi's dot_config, stow's aspects/…)
//   - provisions your declared plugins the way your manager expects them,
//     so the editor never wants the network
//   - boots it, headless, and reads what actually happened: startup time
//     from nvim's own clock, real init errors with their traces folded in,
//     what loaded
//   - fails the build when the editor fails, with the error quoted
//
// The engine is ported from vim.pro's worker (github.com/vim-pro/vim.pro),
// where it boots every connected config — this is the same measurement, run
// where your pull requests live, against the commit being proposed rather
// than whatever the site last synced.
//
// Confinement note: the site's worker runs untrusted strangers' configs and
// sandboxes accordingly. Here the config is YOURS and the machine is an
// ephemeral CI runner (or your own), so the posture is lighter — but the
// editor still gets a scrubbed env, no shell, and a hard timeout.
//
// Zero dependencies. Usage:  node check.mjs [repo-root]

import { spawnSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, existsSync, readFileSync, readdirSync, symlinkSync, appendFileSync, realpathSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { tmpdir } from 'node:os'

const ROOT = realpathSync(resolve(process.argv[2] ?? '.'))
const TIMEOUT = Number(process.env.VIMPRO_CHECK_TIMEOUT_MS ?? 60000)
// fail-on: 'abort' (only a dead init fails) or 'error' (any init error fails)
const FAIL_ON = process.env.VIMPRO_CHECK_FAIL_ON === 'abort' ? 'abort' : 'error'

// ── find the config ────────────────────────────────────────────────────────
// The entry file is init.lua/init.vim in a directory named nvim — which covers
// a bare config repo (init.lua at root of a dir named anything? no: the repo
// IS ~/.config/nvim, so the entry sits at the top), .config/nvim, chezmoi's
// dot_config/nvim, and stow layouts like aspects/nvim/.config/nvim. A vimrc at
// the repo root is the legacy shape and boots via -u.
function walk(dir, out = [], depth = 0) {
  if (depth > 6) return out
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name === '.git' || e.name === 'node_modules') continue
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out, depth + 1)
    else out.push(p.slice(ROOT.length + 1))
  }
  return out
}

export function findEntry(paths) {
  const inits = paths.filter((p) => /(^|\/)init\.(lua|vim)$/.test(p))
  // a dir literally named nvim (or dot_config/nvim etc.) wins; a bare config
  // repo has init.lua at the top with lua/ beside it
  const inNvimDir = inits.filter((p) => /(^|\/|dot_)nvim\/init\.(lua|vim)$/.test(dirname(p) + '/init.x') || /nvim$/.test(dirname(p)))
  const bare = inits.find((p) => !p.includes('/'))
  const chosen = inNvimDir.sort((a, b) => a.length - b.length)[0] ?? bare ?? inits.sort((a, b) => a.length - b.length)[0]
  if (chosen) return { entry: chosen, legacy: false }
  const vimrc = paths.find((p) => /^\.?g?vimrc$/.test(p))
  return vimrc ? { entry: vimrc, legacy: true } : null
}

// ── read the declarations, lightly ─────────────────────────────────────────
// The site's parser is a real parser; this is a scout. It only has to find
// enough to PROVISION — a plugin it misses shows up honestly in the boot
// report as a module the editor could not find, rather than being silently
// fine, so the failure direction is visible, not wrong.
export function scoutPlugins(root, paths) {
  const plugins = new Set()
  let manager = null
  const luaFiles = paths.filter((p) => p.endsWith('.lua')).slice(0, 200)
  for (const p of luaFiles) {
    let text = ''
    try { text = readFileSync(join(root, p), 'utf8') } catch { continue }
    if (/lazypath|require\s*\(\s*['"]lazy['"]\s*\)/.test(text)) manager = manager ?? 'lazy.nvim'
    if (/vim\.pack\.add\b/.test(text)) manager = 'vim.pack'
    // github URLs are unambiguous wherever they appear
    for (const m of text.matchAll(/https:\/\/github\.com\/([\w.-]+\/[\w.-]+?)(?:\.git)?['"]/g)) plugins.add(m[1])
    // owner/repo strings from EVERY lua file. The first version gated on
    // spec-looking paths and missed lua/theprimeagen/lazy/ entirely, which
    // left lazy to network-install thirty plugins inside the measured boot —
    // a 29-second startup that was really a download. Junk is filtered by
    // shape instead: github owners cannot contain dots, path-fragment
    // lookalikes (plugin/30_mini.lua, tests/screenshots) fail the owner or
    // repo shape, and whatever survives wrongly just fails one bounded clone
    // and lands in the unprovisioned warning, which is the visible direction.
    for (const m of text.matchAll(/['"]([A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9][\w.-]*)['"]/g)) {
      const [owner, repo] = m[1].split('/')
      if (/^(textDocument|tags|tests|plugin|plugins|lua|after|doc|custom|scripts)$/.test(owner)) continue
      if (/^\d/.test(repo) || /\s/.test(m[1])) continue
      if (repo.includes('.') && !/\.(nvim|vim)$/.test(repo)) continue
      plugins.add(m[1])
    }
    for (const m of text.matchAll(/Plug\s+['"]([\w.-]+\/[\w.-]+)['"]/g)) { plugins.add(m[1]); manager = manager ?? 'vim-plug' }
  }
  if (existsSync(join(root, '.gitmodules'))) {
    const gm = readFileSync(join(root, '.gitmodules'), 'utf8')
    if (/(^|\/)pack\/[^/\n]+\/(start|opt)\//m.test(gm)) manager = manager ?? 'native packages'
  }
  return { manager, plugins: [...plugins] }
}

// ── provisioning (ported from vim.pro worker/boot.mjs) ─────────────────────
export function provisionPlan(manager, plugins, dataDir) {
  const dirOf = (name) => String(name).split('/').pop()
  const std = join(dataDir, 'nvim')   // stdpath('data') is $XDG_DATA_HOME/nvim
  if (manager === 'lazy.nvim') {
    return [
      { name: 'folke/lazy.nvim', dest: join(std, 'lazy', 'lazy.nvim') },
      ...plugins.map((p) => ({ name: p, dest: join(std, 'lazy', dirOf(p)) })),
    ]
  }
  if (manager === 'vim.pack') {
    return plugins.map((p) => ({ name: p, dest: join(std, 'site', 'pack', 'core', 'opt', dirOf(p)) }))
  }
  return []   // native packages ride the repo's own submodules; unknown managers provision nothing
}

function git(args, { timeoutMs = 120000, cwd } = {}) {
  return spawnSync('git', args, {
    timeout: timeoutMs, killSignal: 'SIGKILL', encoding: 'utf8', cwd,
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
  })
}

// ── stderr classification (ported) ─────────────────────────────────────────
// One error is one error, however many lines its trace takes; download chatter
// is a notice, never an error.
const ERROR_START = /^(E\d+|.*E\d+:|Error|error:|.*Error detected|Failed |fatal:)/
const CONTINUATION = /^(\s|no file |no field |\[C\]:|stack traceback|\.\.\.|\t)/
export function classifyStderr(text) {
  const errors = [], notices = []
  let inError = false
  for (const raw of String(text ?? '').split('\n')) {
    const line = raw.trimEnd()
    if (!line.trim()) continue
    if (/^vim\.pack: Repaired corrupted lock data/.test(line.trim())) continue
    // an error line ending in ':' has said WHERE but not WHAT — the next line
    // is its message body whatever its shape ('No specs found for module …'
    // matches none of the continuation forms, and losing the body turns a
    // diagnosable failure into 'Error in init.lua:' full stop)
    const owed = inError && errors.length && errors[errors.length - 1].endsWith(':')
    if ((CONTINUATION.test(line) || (owed && !ERROR_START.test(line.trim()))) && (inError ? errors.length : notices.length)) {
      if (inError && errors.length && errors[errors.length - 1].split('\n').length < 3) {
        errors[errors.length - 1] += '\n' + line.trim()
      }
      continue
    }
    if (ERROR_START.test(line.trim())) { errors.push(line.trim()); inError = true }
    else { notices.push(line.trim()); inError = false }
  }
  return { errors: errors.slice(0, 12), notices: notices.slice(0, 30) }
}

const DUMP_LUA = `
local out = {}
local _v = vim.version()
out.nvim = string.format('%d.%d.%d', _v.major, _v.minor, _v.patch)
local loaded = {}
for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
  local name = p:match('/pack/[^/]+/[^/]+/([^/]+)/?$') or p:match('/lazy/([^/]+)/?$')
  if name and name ~= 'lazy.nvim' then loaded[name] = true end
end
out.plugins_loaded = vim.fn.sort(vim.tbl_keys(loaded))
io.stdout:write('\\nVIMPRO_CHECK ' .. vim.json.encode(out) .. '\\n')
`

// ── the check ──────────────────────────────────────────────────────────────
export async function runCheck(root = ROOT) {
  const paths = walk(root)
  const found = findEntry(paths)
  if (!found) return { skip: 'no vim config found in this repository' }
  const { entry, legacy } = found

  const scout = scoutPlugins(root, paths)
  const work = mkdtempSync(join(tmpdir(), 'vimpro-check-'))
  try {
    const xdgConfig = join(work, 'config')
    mkdirSync(xdgConfig, { recursive: true })
    if (!legacy) symlinkSync(join(root, dirname(entry)), join(xdgConfig, 'nvim'))

    // native packages: make sure the config dir's submodules are actually
    // present — on a fresh CI checkout they are not, unless the workflow asked
    // for them. Shallow first, full on failure, https whatever .gitmodules says.
    if (existsSync(join(root, '.gitmodules')) && !legacy) {
      const sub = (extra) => git(['-c', 'url.https://github.com/.insteadOf=git@github.com:',
        '-C', root, 'submodule', 'update', '--init', '--jobs', '4', ...extra, '--', dirname(entry)], { timeoutMs: 180000 })
      let sm = sub(['--depth', '1'])
      if (sm.error || sm.status !== 0) sm = sub([])
      // a submodule that still fails will show up in the boot as a missing
      // module, which is the honest place for it
    }

    const dataDir = join(work, 'data')
    const provisioned = [], unprovisioned = []
    const seen = new Set()
    for (const { name, dest } of provisionPlan(scout.manager, scout.plugins, dataDir)) {
      // one destination, one clone: the scout finds folke/lazy.nvim in the
      // bootstrap AND the plan prepends it, and the second clone into the
      // same non-empty directory failed as a spurious warning on every
      // single lazy config in the corpus
      if (seen.has(dest)) continue
      seen.add(dest)
      if (!/^[\w.-]+\/[\w.-]+$/.test(name)) { unprovisioned.push(name); continue }
      mkdirSync(dirname(dest), { recursive: true })
      const r = git(['clone', '--quiet', '--depth', '1', '--no-tags', '--recurse-submodules=no',
        `https://github.com/${name}.git`, dest], { timeoutMs: 60000 })
      if (r.status === 0) provisioned.push(name)
      else unprovisioned.push(name)
    }

    const dump = join(work, 'dump.lua')
    writeFileSync(dump, DUMP_LUA)
    const stFile = join(work, 'startuptime.log')
    const args = ['--headless', '-n', '-i', 'NONE', '--startuptime', stFile,
      '--cmd', 'set shell=/bin/false shellcmdflag=']
    if (legacy) args.push('-u', join(root, entry))
    args.push('-c', `luafile ${dump}`, '-c', 'qa!')

    const boot = () => spawnSync('nvim', args, {
      timeout: TIMEOUT, killSignal: 'SIGKILL', encoding: 'utf8', maxBuffer: 8 << 20,
      env: {
        PATH: process.env.PATH, HOME: work, TMPDIR: work, TERM: 'dumb', LANG: 'C.UTF-8',
        XDG_CONFIG_HOME: xdgConfig, XDG_DATA_HOME: dataDir,
        XDG_STATE_HOME: join(work, 'state'), XDG_CACHE_HOME: join(work, 'cache'),
      },
    })
    const bootMs = () => {
      try {
        const last = readFileSync(stFile, 'utf8').trim().split('\n').at(-1)
        const t = last?.match(/^([\d.]+)/)
        if (t) return Math.round(Number(t[1]))
      } catch { /* no log */ }
      return null
    }

    // THE FIRST BOOT IS SETUP, NOT THE MEASUREMENT. A config legitimately does
    // one-time work on a fresh machine — fetching locked revisions, compiling
    // parsers, downloading a plugin's binary — and ThePrimeagen's "29-second
    // startup" in the corpus was mostly that. Boot once to let it settle (the
    // cost is reported separately), then measure the boots that describe every
    // day after, and take their median — one warm sample still wobbles.
    let r = boot()
    if (r.error?.code === 'ENOENT') return { skip: 'nvim is not installed on this runner' }
    if (r.error?.code === 'ETIMEDOUT' || r.signal) {
      return { entry, manager: scout.manager, provisioned, unprovisioned, aborted: true,
        errors: [`the editor did not finish booting within ${Math.round(TIMEOUT / 1000)}s`], notices: [] }
    }
    const first_ms = bootMs()
    // a dead init fails identically warm — report the boot that failed
    const firstAborted = classifyStderr(String(r.stderr ?? ''))
      .errors.some((e) => /E5113|Error detected while processing|E5108/.test(e))
    let ms = first_ms
    if (!firstAborted) {
      const warm = []
      for (let i = 0; i < 3; i++) {
        const w = boot()
        if (w.error || w.signal) break   // keep what we have
        warm.push({ r: w, ms: bootMs() })
      }
      const timed = warm.filter((w) => w.ms !== null)
      if (warm.length) r = warm[warm.length - 1].r   // steady state speaks
      if (timed.length) ms = timed.map((w) => w.ms).sort((a, b) => a - b)[Math.floor((timed.length - 1) / 2)]
    }

    // both spellings of both roots: macOS reports /private/var for paths that
    // mkdtemp handed us as /var, and a half-scrubbed path reads as gibberish
    let scrubbed = r.stderr ?? ''
    for (const base of [root, work]) {
      for (const variant of [base, realpathSync(base), '/private' + base]) {
        scrubbed = scrubbed.replaceAll(variant + '/', '')
      }
    }
    if (process.env.VIMPRO_CHECK_DEBUG) console.error('── raw stderr ──\n' + scrubbed + '\n── end raw ──')
    const { errors, notices } = classifyStderr(scrubbed)
    const aborted = errors.some((e) => /^E5113|Error detected while processing|E5108/.test(e))
    const marker = (r.stdout ?? '').split('\n').reverse().find((l) => l.startsWith('VIMPRO_CHECK '))
    let dumped = null
    try { dumped = marker ? JSON.parse(marker.slice('VIMPRO_CHECK '.length)) : null } catch { /* partial editor */ }

    return {
      entry, legacy, manager: scout.manager,
      nvim: dumped?.nvim ?? null, ms, first_ms, aborted,
      errors, notices,
      plugins_loaded: dumped?.plugins_loaded ?? [],
      provisioned, unprovisioned,
    }
  } finally {
    try { rmSync(work, { recursive: true, force: true }) } catch { /* best effort */ }
  }
}

// ── report ─────────────────────────────────────────────────────────────────
function summarize(res) {
  const lines = []
  if (res.skip) return { ok: true, lines: [`vim.pro check: skipped — ${res.skip}`] }
  lines.push(`vim.pro check · ${res.entry}${res.manager ? ` · plugins via ${res.manager}` : ''}`)
  if (res.provisioned?.length) lines.push(`  provisioned ${res.provisioned.length} plugin${res.provisioned.length === 1 ? '' : 's'} for the boot`)
  if (res.unprovisioned?.length) lines.push(`  ⚠ could not provision: ${res.unprovisioned.join(', ')}`)
  if (res.aborted) {
    lines.push(`  ✕ FAILS TO BOOT on a clean machine — init aborted`)
  } else if (res.errors.length) {
    lines.push(`  ✕ boots with ${res.errors.length} error${res.errors.length === 1 ? '' : 's'} (${res.ms}ms on nvim ${res.nvim})`)
  } else {
    lines.push(`  ▲ boots clean in ${res.ms}ms on nvim ${res.nvim} · ${res.plugins_loaded.length} plugins load`)
    // one-time setup that dwarfs the steady state is worth a line of its own
    if (res.first_ms && res.ms && res.first_ms > 2 * res.ms + 500) {
      lines.push(`    first boot ${res.first_ms}ms — one-time setup, not counted`)
    }
  }
  for (const e of res.errors) lines.push('    ' + e.split('\n').join('\n    '))
  const failed = res.aborted || (FAIL_ON === 'error' && res.errors.length > 0)
  return { ok: !failed, lines }
}

const isMain = process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())
if (isMain) {
  const res = await runCheck()
  const { ok, lines } = summarize(res)
  console.log(lines.join('\n'))
  // GitHub annotations + job summary, when running as an Action
  if (process.env.GITHUB_STEP_SUMMARY) {
    const md = ['### vim.pro check', '', ...lines.map((l) => l.trim() ? `- ${l.trim()}` : '')].join('\n')
    try { appendFileSync(process.env.GITHUB_STEP_SUMMARY, md + '\n') } catch { /* best effort */ }
  }
  if (!ok) {
    for (const e of res.errors ?? []) console.log(`::error title=vim.pro check::${e.replaceAll('%', '%25').replaceAll('\n', '%0A')}`)
    process.exit(1)
  }
}
