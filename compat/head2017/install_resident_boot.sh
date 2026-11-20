#!/bin/bash
set -euo pipefail
# Apply only to the image whose boot script imports uEnv.txt, after testing
# exactly the same command line through U-Boot's volatile environment.
printf '%s  %s\n' 7013e14923fbe461c4ecd745214fcafcb0ffaddb10865f9135cd8624637359f4 /boot/boot.scr | sha256sum -c
test "$(findmnt -no SOURCE /boot)" = /dev/mmcblk0p1
cma=$(awk '/CmaTotal/ {print $2}' /proc/meminfo)
test "$cma" = 393216
read -r args </proc/cmdline
[[ $args == *' rootfstype=ext4 '* && $args == *' cma=384M' ]]
config="bootargs=$args"
if [[ -e /boot/uEnv.txt ]]; then
    cmp /boot/uEnv.txt <(printf '%s\n' "$config")
    echo 'The verified resident profile is already installed.'
    exit 0
fi
temp=$(mktemp /boot/.resident-env.XXXXXX)
trap 'rm -f -- "$temp"' EXIT
printf '%s\n' "$config" >"$temp"
mv -n -- "$temp" /boot/uEnv.txt
cmp /boot/uEnv.txt <(printf '%s\n' "$config")
sync
echo 'Installed /boot/uEnv.txt. Removing this added file restores the image defaults at next boot.'
