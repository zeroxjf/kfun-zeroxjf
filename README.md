# darksword-kexploit-fun fork

This fork first fixes exploit stability on A18 devices, including the iPhone 16 series.
The A18 path now follows the working Lara-style race flow more closely: marker-initialized
target file contents, stable local remap addresses, nonfatal missed-race handling, and
longer zone-trimming retries.

Credit to rooootdev's [Lara](https://github.com/rooootdev/lara) for the working
kexploit behavior used to stabilize this fork's A18 path.

Fork of `wh1te4ever/darksword-kexploit-fun` for iOS security research.

Building some cool stuff utilizing kernel r/w exploit

## Supported Devices
All iOS/iPadOS 17.0-26.0.1 devices, except A19/M5 devices

## Features
- Escape app sandbox
- Remotely control or force-crash userspace processes
- Arbitrarily overwrite file data on SSV-protected root file systems
- Manipulate UID, GID, and sticky bits for target files
- Disable ASLR by setting `P_DISABLE_ASLR` to `launchd's proc->p_flag`
