#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

[[ $(uname -s) == Darwin && $(id -u) != 0 ]] || { echo 'Run as your normal macOS user, without sudo.' >&2; exit 1; }
[[ -t 0 ]] || { echo 'Run in an interactive terminal so the encryption passphrase stays local.' >&2; exit 1; }
[[ ! -e /Volumes/Code && ! -L /Volumes/Code ]] || { echo '/Volumes/Code already exists. Inspect or unlock it instead of creating another volume.' >&2; exit 1; }

setup_temp=$(mktemp -d)
cleanup() { unset CODE_PASSWORD CODE_CONFIRM; rm -rf "$setup_temp"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
get_key() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

/usr/sbin/diskutil info -plist /System/Volumes/Data > "$setup_temp/data.plist"
code_container=$(get_key "$setup_temp/data.plist" APFSContainerReference)
[[ $code_container =~ ^disk[0-9]+$ ]] || { echo 'Cannot identify the startup APFS container.' >&2; exit 1; }
/usr/sbin/diskutil apfs list -plist "$code_container" > "$setup_temp/container.plist"
index=0
while volume_name=$(get_key "$setup_temp/container.plist" "Containers:0:Volumes:$index:Name" 2>/dev/null); do
  [[ $volume_name != Code ]] || { echo 'A Code volume already exists, possibly locked. Unlock it with Disk Utility.' >&2; exit 1; }
  index=$((index + 1))
done

printf 'Creates one encrypted APFS volume named Code in startup container %s.\n' "$code_container"
printf 'It shares free space with the startup disk; existing volumes are not erased.\n'
printf 'Type Code to continue: '
read -r confirmation
[[ $confirmation == Code ]] || exit 0
sudo -v
printf 'New Code passphrase (save it in your password manager): '
read -rs CODE_PASSWORD
printf '\nRepeat passphrase: '
read -rs CODE_CONFIRM
printf '\n'
[[ -n $CODE_PASSWORD && $CODE_PASSWORD == "$CODE_CONFIRM" ]] || { echo 'Passphrases must be nonempty and match.' >&2; exit 1; }
printf '%s\n' "$CODE_PASSWORD" | sudo -n /usr/sbin/diskutil apfs addVolume "$code_container" APFS Code -stdinpassphrase
unset CODE_PASSWORD CODE_CONFIRM

/usr/sbin/diskutil info -plist /Volumes/Code > "$setup_temp/code.plist"
for assertion in 'VolumeName Code' 'MountPoint /Volumes/Code' 'FilesystemType apfs' 'Encryption true' 'Locked false'; do
  key=${assertion%% *}
  expected=${assertion#* }
  [[ $(get_key "$setup_temp/code.plist" "$key") == "$expected" ]] || { echo 'Volume verification failed; leave it intact and inspect it.' >&2; exit 1; }
done
[[ $(get_key "$setup_temp/code.plist" APFSContainerReference) == "$code_container" ]] || exit 1
sudo /usr/sbin/diskutil enableOwnership /Volumes/Code
sudo chown "$(id -u):$(id -g)" /Volumes/Code
sudo chmod 700 /Volumes/Code
[[ ! -L /Volumes/Code/.fseventsd && ! -L /Volumes/Code/.fseventsd/no_log ]] || exit 1
sudo mkdir -p /Volumes/Code/.fseventsd
sudo touch /Volumes/Code/.fseventsd/no_log
sudo /usr/bin/mdutil -i off /Volumes/Code
printf 'Code is mounted and encrypted. Run ./setup apply --profile work --only storage next.\n'
printf 'Automatic unlock and login ordering still need a reboot test; the script does not save the passphrase.\n'
