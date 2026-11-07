#!/bin/sh
# Install host prerequisites (idempotent). Needs sudo. HOST_PACKAGES from env.
set -eu
todo=
for p in $HOST_PACKAGES; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed' || todo="$todo $p"
done
if [ -n "$todo" ]; then
    echo "installing:$todo"
    # shellcheck disable=SC2086
    sudo apt-get install -y $todo
fi
u=$(id -un)
grep -q "^$u:" /etc/subuid || sudo usermod --add-subuids 100000-165535 "$u"
grep -q "^$u:" /etc/subgid || sudo usermod --add-subgids 100000-165535 "$u"
echo "prereq OK"
