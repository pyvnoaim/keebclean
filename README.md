# keebclean

**Lock your Mac's keyboard and trackpad while you clean them, and watch every key light up as you wipe it.**

![keebclean in the terminal](docs/screenshot.svg)

Most keyboard cleaning apps filter key events after macOS has already seen them, so Caps Lock still toggles, media keys still change the volume and brightness still jumps around. keebclean takes exclusive control of the keyboard at the HID level instead, so nothing you press reaches macOS at all.

## Features

- **A real lock.** Keyboards are seized at the HID level: letters, modifiers, Caps Lock, fn, media and brightness keys are all blocked.
- **Trackpad and mouse blocked too.** Moves, clicks, scrolling and gestures are dropped and the cursor is frozen.
- **A live keyboard in your terminal.** Every key you press lights up, using your actual layout (ANSI or ISO, and the labels of your current input source, e.g. German QWERTZ).
- **See what you missed.** Keys go from dim to white as you wipe them, getting brighter with every pass, and a progress bar counts the cleaned keys.
- **Screen cleaning.** `--screen` also turns every display black, so smudges stand out.
- **Switch sounds.** Drop in your own recordings of a mechanical switch.
- **Safe by default.** Type `unlock` to get your Mac back. A real lock also releases itself after 15 minutes.
- **No dependencies.** One Swift file, builds with the Xcode Command Line Tools.

## Requirements

- macOS on Apple Silicon or Intel (developed on a recent macOS release)
- Xcode Command Line Tools: `xcode-select --install`

## Install

```sh
git clone https://github.com/pyvnoaim/keebclean.git
cd keebclean
make
make install
```

`make install` asks for your password once. It copies keebclean to `/usr/local/libexec/keebclean` (owned by root) and adds a sudo rule for exactly that file, so locking never asks for a password again. It also links `keebclean` into `/usr/local/bin`. Run `make install` again after you rebuild, and `make uninstall` to remove everything.

You can also skip the install and run `./keebclean` from the folder. It asks for your password whenever macOS needs admin rights to lock the keyboard.

## Usage

```sh
keebclean                  # lock keyboard and trackpad, type "unlock" to finish
keebclean --screen         # same, and black out every display
keebclean --timeout 300    # release automatically after 5 minutes (default: 15)
keebclean --test           # show key presses without locking anything, e.g. for screenshots
keebclean --demo           # simulated presses, no permissions needed
keebclean --mute           # no switch sounds
```

## Permissions

macOS asks for these the first time, for the terminal app you run keebclean in:

| Permission | Needed for |
| --- | --- |
| Input Monitoring | reading the keyboard (all modes except `--demo`) |
| Accessibility | blocking the trackpad and mouse |

Both live under **System Settings > Privacy & Security**.

## Switch sounds

keebclean plays recordings from a `sounds` folder next to the binary. None are included, since good recordings are rarely free to redistribute. Add short WAV, AIFF or CAF files named like this:

| File | Plays on |
| --- | --- |
| `press-generic*.wav` | a key press, one picked at random each time (3 to 5 variants sound most natural) |
| `release-generic.wav` | a key release |
| `press-space.wav`, `press-enter.wav`, `press-backspace.wav` | those keys, instead of the generic press |
| `release-space.wav`, `release-enter.wav`, `release-backspace.wav` | releasing those keys |

Trim the silence at the start of each file, or presses will feel delayed. Without any files keebclean is silent.

## How it works

- **Keyboard:** every keyboard HID device is opened with `kIOHIDOptionsTypeSeizeDevice`, which gives keebclean exclusive access, so macOS never receives the input. Devices that refuse (such as the headphone jack remote, which its audio driver holds) are skipped and listed on screen.
- **Trackpad:** trackpads are multitouch devices that can't be seized the same way, so a `CGEventTap` drops pointer events and the cursor is detached from the mouse.
- **Layout:** the key labels come from the current input source via `UCKeyTranslate`, and the physical layout (ANSI or ISO) from `KBGetLayoutType`.

## Limitations

- The power button and Touch ID are not part of the keyboard and can't be blocked. Holding the power button is the last resort if anything ever goes wrong.
- Only built-in MacBook layouts are drawn. External keyboards are locked, but drawn as the MacBook layout.

## License

[MIT](LICENSE)
