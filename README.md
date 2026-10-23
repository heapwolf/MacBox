# MacBox

A small macOS virtual machine app for Apple silicon, built directly on Apple's Virtualization.framework. No third-party dependencies.

- Downloads the latest macOS restore image this Mac supports, or installs from an `.ipsw` you already have
- Suspend and resume: a VM's memory is saved into its package when you suspend it, close its window, or quit the app, and it resumes where it left off
- Shared folders, auto-mounted in the guest under `/Volumes/My Shared Files`
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

## Credits

Originally [MacVM](https://github.com/KhaosT/MacVM) by Khaos Tian.
