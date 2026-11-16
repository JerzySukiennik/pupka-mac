# Pupka for macOS

A native Mac app around the Pupka school notebook: the same editor, drawing layer, board tab and AI panel as https://pupka.gzowo.fun, but single-user and offline. Notes live in files, fonts are bundled, and the assistant can run on a local model.

## What it does

- **Notes as files.** Every card is one `.pupka` file in `~/Documents/Szkoła/Pupka/<Przedmiot>/<data> <temat>.pupka` (JSON with the card's Yjs state plus readable title and text). The index is `Pupka.spis`, pictures are in `Obrazki/`. Renaming a topic or a subject moves the file; deleted cards go to `Kosz/`.
- **One-way pull.** The first launch moves all notes from Pupka online; "Pobierz nowości z Pupki online" (⇧⌘R) later merges new and changed cards. Nothing is ever sent back.
- **Local model.** The AI panel has a Claude / Lokalnie switch. Local mode runs Gemma 4 E4B through a bundled llama.cpp server on two CPU threads (settings: 2, 3 or 4), started on demand, asleep after five idle minutes, stopped when the app quits. Without internet the app switches to local mode by itself.
- **Online extras.** Claude chat, picture search and the board tab go through a native proxy, so they work whenever there is internet.

## Layout

- `Sources/` Swift shell: window and menus (`main.swift`), `pupka://app` scheme with static files, media and streaming proxies (`SchemeHandler.swift`), file store (`NoteStore.swift`), web bridge (`Bridge.swift`), model server (`LocalModel.swift`), test hooks (`Debug.swift`).
- The web app itself comes from the Pupka repo (`../Pupka`); its desktop mode lives there in `src/desktop.js`, `src/deskapp.js` and `src/localai.js` and is inert in the browser.
- `fonts/` Newsreader, Geist, Geist Mono, Montserrat, Inter and Shantell Sans as local woff2 (Google Fonts, SIL Open Font License).

## Build

```bash
./build.sh
```

Builds `build/Pupka.app` and installs it to `/Applications`. Needs the Pupka repo next to this folder (or `PUPKA_WEB=/path`). The llama.cpp binaries are downloaded once by `Niepotrzebne/get-llama.sh` (official release, pinned tag).

The model file is looked up in `~/.gzowo-concierge/local/models/gemma-4-E4B-it-Q4_K_M.gguf` (shared with Gzowo Concierge) and then in `~/Library/Application Support/Pupka/models/gemma-4-E4B_q4_0-it.gguf`.

## Testing without touching real notes

```bash
PUPKA_ROOT=/tmp/pupka-test PUPKA_DEBUG=/tmp/pupka-debug build/Pupka.app/Contents/MacOS/Pupka
```

`PUPKA_ROOT` moves the notes folder and uses a throwaway web data store. `PUPKA_DEBUG` writes the page console to `console.log`, runs `cmd.js` in the page (answer in `out.json`), saves a screenshot when a file named `shot` appears and quits on a file named `quit`.
