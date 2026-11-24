# AkIOS userland

What AkIOS adds to iOS 27.2.1 (24B156, the iPhone 13 mini's userland) on the Pixel 8a: process 1 until Apple's launchd,
the libraries the kernel inserts into a few of Apple's daemons, our daemons and their launchd jobs, the audio device.
`ak userland` (in the umbrella repository) builds it into one APFS image, `out/akios.apfs`.

## Layout

| Path | What |
|---|---|
| `userland.toml` | the manifest: what is built, from what, and where it goes in the image |
| `akinit/` | process 1 (static, libmini): `plan.c` reads the boot plan, one file a job does what its steps say |
| `akinit/test/` | the host test: akinit and the old init against a fake kernel (`fake.c`), their calls compared |
| `src/` | the inserted libraries (`inject/`), the audio plug-in (`audio/`), our daemons (`tools/`), MetalTest |
| `jobs/` | `edits.toml`: the few changes to Apple's launchd jobs; `com.akios.*.plist`: ours |
| `etc/` | `boot.plan.in` (the plan's template), files put on the data volume |

## How it boots

The loader hands the kernel `akios.apfs` as its RAM disk (md0, `rd=md0`), and the kernel starts its `/sbin/launchd`,
which is akinit. akinit runs `/etc/akios/boot.plan`: it mounts the iPhone system volume (`root_apfs=`) read only on
`/flash`, binds our launchd jobs, audio plug-ins and `/fw` over it, makes it the root (this image moves to
`/private/preboot`, `/akita` is bound back from there), mounts the cryptexes (`cryptex_dev=`) and the data volumes
(`var_hfs=`, the other `ufs_ios_*`), fills in the data volume, tells the kernel which programs get which library, and
execs Apple's launchd. At run time our files are under `/akita` (the kernel's boot line names
`/akita/lib/HakiosMetal` and `/akita/share/ca-share/...`), the firmware is `/fw` of the image, where the drivers look.

The plan is text, one step a line, with conditions on boot arguments and flags (`akinit/plan.h`):

    section flash-root if bootarg:root_apfs
    must mount apfs /dev/$root_apfs /flash ro
    bind /akita/xpc /flash/System/Library/xpc
    must switchroot /flash private/preboot
    end

## Building

    ./ak userland                 # from the umbrella: out/akios.apfs, logs in ~/akita/logs/ak/userland-*/
    ./ak userland --oslog com.apple.backboardd,com.apple.SpringBoard    # those jobs log to the console

The tools, the SDK, the unpacked IPSW and the firmware are named in the umbrella's `akios.toml` `[userland]`. ak checks
the plan with a host build of akinit and reads the image back with an independent reader; with apfsprogs' apfsck in
the umbrella's `.cache/apfsprogs` it runs that too (`git clone https://github.com/linux-apfs/apfsprogs` there, `make
-C apfsck`). The host test against the old init:

    akinit/test/compare.sh OLD/userland/src/init.c OLD/userland/root ../work/userland/image OUTDIR root_apfs=... var_hfs=...

## License

Our code: BSD-2-Clause-Patent (`LICENSE`). Code that came over from the old tree keeps its header.
