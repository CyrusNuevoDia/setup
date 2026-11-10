# Agent instructions

- Run `./setup verify --json` and inspect `./setup plan --json` before applying a stage. Use `--only` for targeted changes. `apply --dry-run` previews without writing files.
- Use `storage/README.md` to establish or unlock the encrypted Code volume. A populated local directory requires a separate migration plan.
- Respect the target Mac's management policies. Use the installation routes in the app manifest and report pending items individually.
- Keep credentials, account settings, machine captures, and private asset bundles out of Git. Pass asset directories through `--assets`.
- Run `/usr/bin/ruby test/setup_test.rb` after changing the CLI. A temporary `--home` supports the links, fonts, and Alfred stages.

This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.
