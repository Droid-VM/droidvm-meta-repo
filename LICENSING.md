# Licensing

This repository holds two kinds of material and they are licensed differently.

## Material inherited from upstream

- **crosvm** (BSD-3-Clause) — https://chromium.googlesource.com/crosvm/crosvm
- **virglrenderer** (MIT) — https://gitlab.freedesktop.org/virgl/virglrenderer
- **gfxstream** (Apache-2.0) — https://android.googlesource.com/platform/hardware/google/gfxstream
- **Mesa** (MIT) — https://gitlab.freedesktop.org/mesa/mesa

Every file that came from an upstream project stays under that project's
license. Nothing here relicenses it, and modifications to those files do not
relicense them either — a patched upstream file is still an upstream file.

## Material written for DroidVM

Files carrying `SPDX-License-Identifier: GPL-3.0-or-later` are DroidVM work
and are licensed under the GNU GPL, version 3 or later, **with the
additional permissions in `ADDITIONAL-PERMISSIONS`**.

Those permissions exist so this work can go upstream. They let anyone
relicense it under the terms an upstream project requires, for the purpose of
getting it merged there — and only for that purpose. Once upstream publishes
it, upstream's license governs that copy.

## Third-party material that is neither

`guest-patches/` holds patches against upstream mesa; the context and removed
lines in them are upstream's. `deploy/` scripts drive a phone and a guest and
are DroidVM work.

## Contributing

See `CONTRIBUTING.md`. Sign-off is required; there is no CLA.
