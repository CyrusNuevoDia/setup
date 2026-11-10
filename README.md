# Mac work setup

Set up a work Mac with Homebrew, mise, and a work app catalog. Developer tools and caches live on an encrypted APFS volume named `Code`.

## Preview the setup

Install the macOS Command Line Tools if Git prompts you for them. Clone this repo to a permanent directory you own and keep it there so configuration links continue to resolve.

```sh
git clone https://github.com/CyrusNuevoDia/setup.git ~/setup-bootstrap
cd ~/setup-bootstrap
./setup verify --json
./setup plan --json
```

The plan lists the storage aliases, packages, configuration links, and app installation routes. To preview a particular stage, pass `--only storage`, `--only packages`, `--only apps`, or `--only links`.

## Set up the work Mac

1. If your organization manages the Mac, check its software and storage policy before adding a volume or installing apps.
2. Create or unlock an encrypted `Code` volume. Follow the [storage guide](storage/README.md).
3. Install Homebrew through [brew.sh](https://brew.sh), then apply the plan.

   ```sh
   ./setup apply --json
   ./setup check --json
   ```

4. Use the reported vendor or App Store routes for pending apps. Sign in and enter licenses on the Mac as needed.
5. To activate mise in Zsh, add `eval "$(mise activate zsh)"` to `~/.zshrc` after Homebrew's shell initialization.

The storage stage creates `~/.local`, `~/.cache`, and `~/Git/work` as aliases on `Code`. It stops if it encounters an existing populated directory. Setup backs up conflicting configuration files under `~/.setup-backups/` before linking replacements.

The app catalog is in `apps/manifest.json`, Homebrew tools are in `brew/Brewfile`, and runtime versions are in `config/mise/config.toml`. Sign-ins, app preferences, SSH configuration, and personal settings are configured on the destination Mac.

## Restore fonts and Alfred preferences

Transfer your private asset bundle to the Mac and extract it. Pass the extracted `assets` directory to setup. The bundle has `fonts/manifest.json` and `alfred/manifest.json` with SHA-256 hashes for the captured files.

```sh
./setup plan --only fonts,alfred --assets /path/to/assets --json
./setup apply --only fonts,alfred --assets /path/to/assets --json
```

Setup verifies the bundle before copying fonts into `~/Library/Fonts` and staging a separate Alfred preferences folder. Open Alfred Preferences, go to **Advanced**, and choose the `syncFolder` from the output. Alfred activation and local permissions require separate setup. Keep the bundle in an approved private transfer location or under the checkout’s ignored `local/` directory.

`0` means the command succeeded, `1` means it failed, and `2` means it found pending work. Run the Ruby tests with `/usr/bin/ruby test/setup_test.rb`.
