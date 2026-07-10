# Release safety

This package is built from source only. It intentionally excludes:

- `config.lua` and its backup variants
- KOReader runtime settings such as `settings/weread.lua`, `.old`, and `.new`
- cookies, API keys, QR-login tokens, account metadata, caches, and downloaded books
- editor/OS metadata and bundled font binaries

For a clean-install privacy test, fully exit KOReader, remove the existing plugin directory and `settings/weread.lua*`, then install this package and restart KOReader.
