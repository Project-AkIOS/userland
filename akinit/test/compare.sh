#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause-Patent
#
# The host test: the old init (the old tree's userland/src/init.c) and akinit with the plan ak userland wrote, both
# built for the PC against test/fake.c and run on the same made-up phone (test/world.txt) with the same boot line;
# what each asks the kernel for ("@" lines), side by side. The old init's self-tests (between its "read-only
# filesystem" heading and its count of checks) are left out: akinit has none.
#
# usage: akinit/test/compare.sh OLD_INIT_C OLD_IMAGE_DIR NEW_IMAGE_DIR OUTDIR [BOOT-ARGS...]
#   OLD_IMAGE_DIR  what the old init sees as /akita (the old tree's userland/root)
#   NEW_IMAGE_DIR  the staged image (work/userland/image)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OLD=$1 OLDIMG=$2 NEWIMG=$3 OUT=$4
shift 4
ARGS="$*"
mkdir -p "$OUT"
CFLAGS="-std=gnu11 -O1 -w -fno-builtin -I$HERE"
cc $CFLAGS -o "$OUT/init-host" "$OLD" "$HERE/fake.c"
cc $CFLAGS -o "$OUT/akinit-host" "$HERE"/../{main,plan,ops,fsutil,datavol,skel,gestalt,bootlog,run,inject}.c "$HERE/fake.c"
export FAKE_WORLD=$HERE/world.txt FAKE_BOOTARGS="$ARGS"
# the old init: /akita is its image (md1), started by that name; the boot volume (md0) had a /fw
(FAKE_MAP="/akita=$OLDIMG:/fw=$OLDIMG/fw" exec -a /akita/sbin/init "$OUT/init-host") > "$OUT/old.log" 2>&1 || true
FAKE_MAP="/akita=$NEWIMG/akita:/fw=$NEWIMG/fw:/etc/akios=$NEWIMG/etc/akios" "$OUT/akinit-host" /etc/akios/boot.plan > "$OUT/new.log" 2>&1 || true
awk '/^-- read-only filesystem --/{skip=1} /^=== [0-9]+ checks/{skip=0} !skip && /^@ /' "$OUT/old.log" > "$OUT/old.calls"
grep '^@ ' "$OUT/new.log" > "$OUT/new.calls" || true
diff -u "$OUT/old.calls" "$OUT/new.calls" > "$OUT/calls.diff" && echo "compare: the same calls" || echo "compare: differences in $OUT/calls.diff ($(grep -c '^[-+][^-+]' "$OUT/calls.diff") lines)"
