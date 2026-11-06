# Testing on macOS 26

The host OS controls native appearance; selecting Xcode 26 on macOS 27 does not
reproduce macOS 26. On an Apple Silicon Mac, use a [Tart VM](https://tart.run/quick-start/):

```sh
brew install cirruslabs/cli/tart
./script/macos26_vm.sh setup
./script/macos26_vm.sh run
```

The VM and downloads stay under `build/macos26-vm`. Its public image includes
Xcode 26.5 and downloads about 70 GB compressed; it can exercise the macOS 26
appearance, while CI remains the exact Xcode 26.6 gate. Set `LATEST_VM_IMAGE` to a
matching image when one is available. Log in with the image's `admin`/`admin`
account through `tart exec`; the VM runner has no visible graphics. Setup fixes the guest display at 1440×900 pixels and 1× scale for the
CI visual references. The host checkout is shared read-only; clone it onto the guest disk:

```sh
git clone --no-hardlinks '/Volumes/My Shared Files/latest' ~/Latest
cd ~/Latest
brew install ripgrep
./script/build_and_run.sh
./script/test.sh --all
cp -R build/production-visuals '/Volumes/My Shared Files/artifacts/'
```

Tests and app checks stay invisible in the guest as well. For an exact compiler
reproduction, install Xcode 26.6 in the guest and set `DEVELOPER_DIR` to its
`Contents/Developer` directory. CI also uploads its real macOS 26 production
window captures with each run's test-results artifact.

Earlier macOS 26 appearance references remain available, but the invisible test guard
never activates a window or hands focus to another application. Do not disable the
guard to reproduce historical foreground captures.
