# ChroMagician

ChroMagician is the desktop companion for [ChroMagic](https://github.com/cursedtoast2/ChroMagic). Plug your Chromatic into your PC to back up cartridges, restore saves, and organize your SD card without taking it out of the handheld.

## Cartridge and SD tools

- See the inserted game's cover art and information.
- Back up games and saves to your PC or the Chromatic's SD card.
- Restore saves to a cartridge.
- Write homebrew to supported rewritable cartridges.
- Copy, rename, move, and delete SD files, with folder management and multi-select.
- Install ChroMagic or restore stock firmware from ModRetro's releases.

## Install

Download an installer from [Releases](https://github.com/cursedtoast2/ChroMagician/releases):

- **Windows:** the `Setup.exe` installer.
- **Linux:** the `.deb` or `.rpm` package for your distribution.

Portable packages are also available. Flashing tools and their runtimes are included.

Run [ModRetro's MRUpdater](https://support.modretro.com/en_us/chromatic-firmware-updater-ryhoYnzCx) and complete its USB setup, then close it before opening ChroMagician.

## Connect your Chromatic

Turn on your Chromatic and connect it over USB. If it's running stock firmware, use **Firmware → Install ChroMagic**.

For cartridge and SD tools, enable **SYSTEM → C. MAGICIAN** on the handheld. The inserted game will appear in the app. With an SD card installed, the **SD Card** tab lets you manage its files.

[Website and guide](https://chromagic.org)

## Source and credits

`flutter/` contains the desktop app, installers, and update tools. `crates/` contains the cartridge backend.

See [LICENSE](LICENSE) and [NOTICE](NOTICE) for licenses and upstream credits.

By [CursedToast](https://x.com/CursedToastSDA). An independent project, not affiliated with ModRetro or Nintendo.
