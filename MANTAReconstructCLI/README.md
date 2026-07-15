# manta-reconstruct

A standalone macOS command-line tool that runs MANTA's photogrammetry
reconstruction (RealityKit Object Capture) on a captured bundle — so you can
grind through a heavy reconstruction in the terminal while continuing to work
in the MANTA app / receiver.

It is its own Swift package. It links [`MANTACore`](../MANTACore) via a local
path dependency (bundle import/validation, point-cloud loading, world
alignment) and reproduces the receiver's Object Capture driver. It does **not**
touch the app or `MANTA.xcodeproj`.

## Build

```sh
cd MANTAReconstructCLI
swift build -c release
```

The binary lands at `.build/release/manta-reconstruct`. Symlink it somewhere on
your `PATH` if you like:

```sh
ln -sf "$(pwd)/.build/release/manta-reconstruct" /usr/local/bin/manta-reconstruct
```

## Use

```sh
# From a .manta archive, Full detail (default):
manta-reconstruct /path/to/capture.manta

# From an already-extracted bundle directory, Raw detail, custom output:
manta-reconstruct /path/to/bundleDir --detail raw --output ~/Desktop/recon
```

Options: `-d/--detail medium|full|raw`, `-o/--output DIR`,
`--keep-workspace`, `-h/--help`. Progress and logs go to stderr; the final
`model.usdz` path is printed to stdout (handy for scripting). Ctrl-C cancels
cleanly and releases the GPU.

### Outputs (written into `--output`)

| File | Contents |
| --- | --- |
| `model.usdz` | Reconstructed textured mesh |
| `poses.json` | Per-image camera poses (ARKit world, meters) |
| `diagnostics.json` | Timing, skipped samples, LiDAR-alignment metrics |

## Note on shared code

The reconstruction driver in `Sources/manta-reconstruct/Reconstruction.swift`
is a port of the receiver's `ReceiverPhotogrammetryReconstruction.swift`. The
two are intentionally decoupled (this package makes no changes to the app), so
if the receiver's reconstruction logic changes, port the change here too.
