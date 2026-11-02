# Contributing to Lectern

Thanks for helping. Lectern aims to be a small, fast, native Mac editor, so a change is most welcome when it makes everyday editing better without adding settings or clutter.

## Before you start

- **Bugs:** open an issue with steps to reproduce, or go straight to a pull request for small, obvious fixes.
- **Features:** please open an issue first, so we can agree it fits before you spend time on it.

## Building

You need Xcode 16 or later and macOS 15 or later.

```sh
./build.sh       # builds and installs /Applications/Lectern.app (signed ad hoc)
swift build      # just compiles
```

Open `Package.swift` in Xcode if you want to work in Xcode. The `sample/` folder has a file for each previewer: Markdown with Mermaid, JSON, YAML and `.env`.

## Code

- The app is AppKit with SwiftUI views inside. `AppDelegate.swift` holds the app, the menus and windows. `Workspace.swift` is a window's state. `WorkspaceView.swift` is its UI.
- The editor is a TextKit 1 `NSTextView` (`CodeEditor.swift`). Syntax colours come from `SyntaxHighlighter.swift`.
- `Git/` is the source control code. It reads repositories directly, and makes changes by running the user's own `git`.
- Match the style of the code around your change: names, comment density, and short comments that say *why*.
- Lectern doesn't send anything over the network on its own. Please keep it that way.

## Pull requests

- Keep each pull request to one change, and describe how you checked it. Include screenshots for UI changes.
- Make sure `swift build` succeeds. CI also builds every pull request.
- By contributing, you agree that your work is released under the [MIT License](LICENSE).
