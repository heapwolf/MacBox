# MacBox

A small virtual machine app for macOS and Linux guests on Apple silicon, built directly on Apple's Virtualization.framework. No third-party dependencies.

- Downloads the latest macOS restore image this Mac supports, or installs from an `.ipsw` you already have
- Suspend and resume: a VM's memory is saved into its package when you suspend it, close its window, or quit the app, and it resumes where it left off
- Linux guests from any ARM64 installer ISO, with clipboard sharing for guests running `spice-vdagent`
- Shared folders, auto-mounted in macOS guests under `/Volumes/My Shared Files`; in Linux, `mount -t virtiofs macbox /mnt`
- Guest display resizes to fit the window
- CPU, memory, and shared folders are editable while the VM is shut down

VMs live in `~/Library/Containers/com.heapwolf.MacBox/Data/Library/Application Support/VMs`, one folder each with its config, disk, NVRAM, and saved state.

Requires macOS 15 or later on Apple silicon.

## Building

```sh
make            # debug build -> build/debug/MacBox.app
make run        # build and launch
make release    # optimized build -> build/release/MacBox.app
```

`swift build` compiles the app, but Virtualization.framework only runs in a process signed with the `com.apple.security.virtualization` entitlement. The Makefile wraps the binary into an app bundle and signs it with `App/MacBox.entitlements`. It signs ad-hoc by default. To sign with your own identity, pass it in:

```sh
make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" release
```

## Rosetta in Linux guests

Turn on Rosetta in a Linux VM's settings (MacBox offers to install it if needed), then set it up inside the guest:

```sh
sudo mkdir -p /media/rosetta
sudo mount -t virtiofs rosetta /media/rosetta
sudo /usr/sbin/update-binfmts --install rosetta /media/rosetta/rosetta \
    --magic "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00" \
    --mask "\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff" \
    --credentials yes --preserve no --fix-binary yes
```

To mount it at boot, add `rosetta /media/rosetta virtiofs ro,nofail 0 0` to `/etc/fstab`.

## Credits

Originally [MacVM](https://github.com/KhaosT/MacVM) by Khaos Tian.
