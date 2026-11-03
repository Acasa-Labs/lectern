# Lectern

**A native Mac editor for code and text.** Lectern comes with a folder sidebar, tabs, git and a terminal. Markdown, JSON and YAML get live previews.

Lectern is written in Swift with AppKit and SwiftUI. It has no Electron, no web views for editing, no accounts and no telemetry. It opens fast, follows your Mac's look and settings, and stays out of the way.

> Lectern is an editor, not an IDE. It doesn't build, run or debug your code. It opens a folder and makes reading and changing files pleasant, with the git and terminal you already use beside them.

## Features

- **Editor:** syntax highlighting for Swift, JavaScript/TypeScript, Python, shell, HTML/XML, CSS, C-family languages, Markdown, JSON, YAML and `.env` files. Also line numbers, the current-line highlight, bracket matching, word-occurrence highlights, auto-indent, word wrap and a minimap.
- **Previews:** Markdown is rendered with tables, task lists and code blocks, plus **Mermaid diagrams**. JSON is shown as a colour-coded tree that you can fold. Press ⌘E to switch between editing and the preview.
- **Workspace:** a folder sidebar, tabs (pin, colour, rename, bookmark), Quick Open (⌘P), Find in Folder (⇧⌘F), Back and Forward, and a jump bar. Lectern reopens your last session, and keeps recent folders and files.
- **Source Control:** stage, unstage and discard files; commit, amend, fetch, pull and push; switch or create branches; stash. There's also a full history and diff viewer. Changes are made with your own `git`, so your config, hooks, signing and credentials all apply.
- **Terminal tabs:** your login shell (zsh, your `.zshrc` and PATH) in a tab. You can also open a folder in iTerm or Terminal.
- **SSH tabs:** connect to hosts from `~/.ssh/config` or saved servers. Lectern uses your Mac's own `ssh` and keys.
- **File types:** Lectern can be the default app for Markdown, YAML and `.env` files, and can open JSON files and folders.

## Install

Download the latest `Lectern.dmg` from [Releases](../../releases), open it, and drag Lectern to Applications. Builds are signed with a Developer ID and notarized by Apple.

Lectern can keep itself up to date. On its second launch it asks whether to check for updates automatically; you can change your answer, or check now, from the Lectern menu.

Lectern needs **macOS 15 Sequoia or later** and runs on Apple silicon and Intel Macs.

To make Lectern the default app for a file type, open a file's **Get Info** window in Finder (⌘I), choose Lectern under **Open with**, then click **Change All…**.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Quick Open | ⌘P |
| Find in Folder | ⇧⌘F |
| Toggle preview | ⌘E |
| Toggle sidebar | ⌘B |
| Source Control | ⌥⌘G |
| New terminal tab | ⌃\` |
| Connect to server | ⇧⌘K |
| Open folder in iTerm/Terminal | ⌃⇧\` |
| Back / Forward | ⌃⌘← / ⌃⌘→ |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Bookmark tab | ⌘D |
| Word wrap | ⌥Z |
| Minimap | ⌃⇧⌘M |
| Commit (in Source Control) | ⌘↩ |

## Privacy

Lectern makes no network requests of its own, apart from update checks: no telemetry and no accounts. Update checks happen only if you turn them on (Lectern asks once) or choose Check for Updates. Each check downloads one file, the update feed from this repository's GitHub releases, and sends nothing about you or your files. The network is used only by commands you run (`git fetch`/`pull`/`push`, `ssh`, and whatever you type in a terminal tab) and by images that a Markdown file links to on the web. Markdown previews don't run the page's own JavaScript. Clicked web and mail links open in your browser or mail app.

## Build from source

You need Xcode 16 or later (Swift 6).

```sh
git clone https://github.com/Acasa-Labs/lectern.git
cd lectern
./build.sh            # builds, signs ad hoc and installs to /Applications/Lectern.app
```

Running `swift build` alone builds the binary. The app bundle is put together by [`scripts/assemble.sh`](scripts/assemble.sh). The `sample/` folder has test files for each previewer.

Maintainers make signed, notarized releases with [`scripts/release.sh`](scripts/release.sh). See [RELEASING.md](RELEASING.md).

## Contributing

Bug reports and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Lectern is meant to stay small, so please open an issue before starting on a large feature.

## License

Lectern is released under the [MIT License](LICENSE). It includes third-party code listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
