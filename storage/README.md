# Encrypted Code volume

Setup uses an encrypted, writable APFS volume at `/Volumes/Code`. It places `~/.local`, `~/.cache`, and `~/Git/work` on that volume.

If `Code` already exists, unlock and mount it in Disk Utility. If it is missing and your organization permits an additional volume, run the creation script from an interactive Terminal.

```sh
./storage/create-code-volume.sh
./setup apply --only storage --json
```

The script adds a volume in the startup APFS container, prompts for a local encryption passphrase, enables ownership, and disables indexing and persistent FSEvents logs on `Code`. Keep the passphrase in your password manager or Keychain according to your organization’s policy.

If setup reports a populated directory or conflicting link, inspect and migrate it separately. After rebooting, unlock the volume and verify it before relying on the aliases.

```sh
./setup check --only storage --json
```
