# Easy Img

A fast, keyboard-driven image viewer for macOS. Open an image and flip through every picture in its folder with the arrow keys, browse folders as thumbnails, zoom into large photos, and ask an AI about what you're looking at.

Native AppKit, no dependencies, about 2 MB.

## Features

### Browsing
- **Arrow-key browsing**: open any image and use **←** / **→** to go through every image in the same folder (wraps around at the ends).
- **Open folders**: open a folder to browse all of its images.
- **Finder integration**: *Open With → Easy Img* for images, *Quick Actions / Services → Open in Easy Img* for images and folders, or drop files and folders on the Dock icon.
- **Folder sidebar**: a folder tree (Desktop, Documents, Downloads, Pictures, Home, drives) to jump to any directory.
- **Thumbnail grid**: see a whole folder at once and pick an image. Thumbnails show the whole picture by default or can be cropped to even squares.
- **Filmstrip**: a strip of thumbnails under the image, centred on the current one.
- Smart sorting that matches Finder (`img2` comes before `img10`), EXIF orientation, animated GIF/PNG/WebP, HEIC, RAW and everything else macOS can read.

### Viewing
- **Zoom** with `+` / `-`, fit to window with `0`, actual size with `1`, or pinch on the trackpad.
- **Scroll and pan** large images with the trackpad, scroll wheel or by dragging.
- **Minimap**: when the image is bigger than the window, a small overview shows which part you're looking at; click or drag in it to move around.
- Large photos load at screen resolution for speed, then at full resolution as you zoom in.
- Full screen, dark interface.

### Copying
- Copy the path of the current image (**⌥⌘C**) or its folder (**⇧⌥⌘C**).
- Copy the image itself (**⌘C**) to paste into Messages, Mail or a document.
- Right-click an image, thumbnail or sidebar folder for *Copy Path*, *Copy Folder Path*, *Copy Name*, *Copy Image* and *Show in Finder*.

### Ask AI
Chat about the image you're viewing: what's in it, translate or summarize the text it contains, where a photo might have been taken, and so on.

- **Providers**: Claude (Anthropic), OpenAI, Google Gemini, DeepSeek, Kimi (Moonshot), and any **OpenAI-compatible server** (OpenRouter, Ollama, LM Studio…).
- **Your own API keys**, stored in the macOS Keychain.
- **Text-only models** (such as `deepseek-v4-pro`) get an on-device description of the image instead: objects detected and text recognized by macOS, without the image itself being sent.
- **Cost tracking**: each answer shows its estimated cost; *Settings → Costs* shows spending this month and per model, recent requests, and an editable price table.
- **Spending limit**: an optional monthly limit that warns at 80% and asks before going over.
- **Privacy**: an image is only sent to an AI provider when you ask a question about it.

## Requirements

- macOS 14 (Sonoma) or later
- To build: Xcode or the Xcode Command Line Tools (`xcode-select --install`)

## Build and install

```sh
git clone https://github.com/LeonardoRO/easy-img-app.git
cd easy-img-app
./build.sh            # builds "build/Easy Img.app" (Apple silicon + Intel)
./build.sh --install  # also copies it to /Applications and registers it with Finder
```

The build script compiles the Swift sources with `swiftc` (no Xcode project needed), draws the app icon, and signs the app with the best certificate in your keychain (Developer ID, then Apple Development, then ad-hoc), always with the hardened runtime.

### Distribution build

```sh
./build.sh --release   # creates build/Easy-Img-<version>.dmg
```

With a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application) and a notarization profile created once with

```sh
xcrun notarytool store-credentials easyimg --apple-id <your-apple-id> --team-id <your-team-id>
```

the DMG is signed, notarized by Apple and stapled, so it opens on any Mac without warnings. Without them, the DMG is still created, but other Macs block it until the user clicks *Open Anyway* in System Settings → Privacy & Security.

To make Easy Img the default viewer for a file type: select an image in Finder → *Get Info* → *Open with: Easy Img* → *Change All…*.

> When the app is signed ad-hoc (no Apple certificate in your keychain), macOS asks for permission to read the saved API key from the Keychain after each rebuild. Choose *Always Allow*. Signed with an Apple certificate, it only asks once.

## Keyboard shortcuts

| Action | Keys |
|---|---|
| Previous / next image | ← / → (also ↑ / ↓, Page Up / Page Down, ⇧Space / Space, ⌘[ / ⌘]) |
| First / last image | Home / End, ⇧⌘[ / ⇧⌘] |
| Thumbnail grid on/off | G |
| Open selected thumbnail | Return, Space or double-click |
| Back to the grid | Esc |
| Zoom in / out | + / − (⌘= / ⌘−) |
| Fit to window / actual size | 0 / 1 (⌘0 / ⌘1) |
| Bigger / smaller thumbnails (grid) | + / − |
| Show/hide sidebar | ⌃⌘S |
| Ask AI | ⌘K |
| Copy image / path / folder path | ⌘C / ⌥⌘C / ⇧⌥⌘C |
| Show in Finder | ⌘R |
| Open… | ⌘O |
| Full screen | ⌃⌘F |
| Settings | ⌘, |
| Help | ⌘? |

## Setting up Ask AI

1. Open **Easy Img → Settings… → AI**.
2. Choose the **Assistant** provider and paste its **API key**.
3. Optionally press **Load Models** to pick another model from the provider's list.
4. Press **⌘K** (or the ✨ toolbar button) and ask about the image.

For a custom OpenAI-compatible server, enter its address (for example `http://localhost:11434/v1` for Ollama), type the model name, and tick *The custom server's model can see images* if it supports images.

Costs are estimates calculated from the token usage each provider reports and the prices on the *Costs* tab. Prices change; check your provider's pricing page and update the table if needed. Your provider's bill is the final word.

## Roadmap

- AI image editing: precise edits (crop, rotate, adjust, remove background, blur faces) done on the Mac, plus generative edits with OpenAI or Gemini (Nano Banana), saved as new files next to the original.
- AI search: find images by describing them, using an on-device index.

## Project layout

| Path | Contents |
|---|---|
| `Sources/` | Swift sources (AppKit) |
| `Resources/` | `Info.plist` and the help page |
| `scripts/make-icon.swift` | Draws the app icon |
| `build.sh` | Build, sign and install script |

## License

Copyright © 2026 Leonardo Ribeiro Oliveira. Released under the [MIT License](LICENSE).
