# Agent instructions

- Run `./setup verify --json` and inspect `./setup plan --json` before applying a stage. Use `--only` for targeted changes. `apply --dry-run` previews without writing files.
- Use `storage/README.md` to establish or unlock the encrypted Code volume. A populated local directory requires a separate migration plan.
- Respect the target Mac's management policies. Use the installation routes in the app manifest and report pending items individually.
- Keep credentials, account settings, and machine captures out of this public repository.
- Run `/usr/bin/ruby test/setup_test.rb` after changing the CLI. A temporary `--home` supports testing the links stage.
