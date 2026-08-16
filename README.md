# vim.pro check

**CI for your editor.** Your code gets a test suite; your editor config gets
pushed and prayed over. This action boots your nvim config on the runner — a
genuinely clean machine — with your declared plugins provisioned, and fails
the build if the editor fails. The error that stops your init is quoted, not
summarized.

```yaml
# .github/workflows/vim.yml
name: vim.pro check
on: [push, pull_request]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: vim-pro/check@v1
```

What it does, in order:

1. **Finds your config**, whatever the layout — a bare config repo,
   `.config/nvim`, chezmoi's `dot_config/nvim`, stow-style
   `aspects/nvim/.config/nvim`, or a legacy `vimrc`.
2. **Provisions your plugins** the way your manager expects them — lazy.nvim,
   vim.pack, native packages via your submodules — so the boot measures your
   config, not your network.
3. **Boots it, headless**, and reads what actually happened: startup time from
   nvim's own clock, real init errors with their traces folded in, which
   plugins actually loaded.
4. **Fails the build when the editor fails.** A config that dies on a clean
   machine is exactly the thing you want to learn from a pull request rather
   than from a new laptop.

Options:

```yaml
- uses: vim-pro/check@v1
  with:
    nvim-version: nightly   # default: stable — run both jobs to get early warning
    fail-on: abort          # default: error — 'abort' only fails a dead init
```

The engine is the same one [vim.pro](https://vim.pro) uses to boot every
connected config. Run it locally too: `node check.mjs` from your dotfiles
root, with `nvim` and `git` on your PATH. No dependencies.
