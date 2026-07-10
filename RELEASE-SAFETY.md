# Release safety

This package intentionally excludes user-specific and runtime data:

- `config.lua` and backup variants
- KOReader runtime settings such as `settings/weread.lua`, `.old`, and `.new`
- cookies, API keys, QR-login state, account metadata, caches, and downloaded books
- editor and OS metadata

Runtime source modules and the bundled emoji font are included because they are required for normal plugin operation.

For a clean-install privacy test, fully exit KOReader, remove the existing plugin directory and `settings/weread.lua*`, then install this package and restart KOReader.
