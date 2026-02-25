---
name: add-feature-skill
description: >
  Guide for adding new features to PortSentry. Covers architecture,
  extension points, patterns, and build process.
---

## Overview

PortSentry is a macOS menu bar app that monitors TCP listening ports, showing which processes are bound to which ports with category filtering, search, and the ability to kill processes.

## Architecture

PortSentry is a single-file SwiftUI menu bar app (`PortSentry.swift`, ~571 lines). The `@main` struct `PortSentryApp` owns a `@State PortScanner` instance as the single source of truth. The scanner shells out to `/usr/sbin/lsof -iTCP -sTCP:LISTEN -n -P` every 5 seconds, parses the output, and exposes a filtered/sorted port list. The popup UI renders inside a `MenuBarExtra(.window)` scene with a fixed size defined by `SentryTheme`.

State flows one way: `PortScanner` holds all mutable state (`ports`, `searchText`, `selectedCategory`, `killConfirmation`, `killResult`), views read from it via `@Bindable`, and user actions call scanner methods. The `@Observable` macro drives SwiftUI updates.

## Key Types

- **`ListeningPort`** (struct, Identifiable, Hashable) -- Represents a listening TCP port. Fields: `id` ("pid:port" string), `port` (UInt16), `pid` (Int32), `processName`, `user`, `address` (bind address, e.g., "127.0.0.1" or "*"). Computed property: `category`.
- **`PortCategory`** (enum, CaseIterable, 5 cases: `webDev`, `backend`, `database`, `system`, `other`) -- Categorizes ports by port number ranges via `static func categorize(_ port: UInt16)`. Each case provides an `icon` (SF Symbol) and `color`.
- **`KillResult`** (enum, 3 cases: `success`, `failed(String)`, `alreadyDead`) -- Result type for process termination attempts.
- **`PortScanner`** (@Observable class) -- Core scanner. Runs `lsof` to discover listening ports, deduplicates by pid:port, supports category filtering and text search via `filteredPorts`. Provides `killProcess()` which sends SIGTERM, waits 500ms, then SIGKILL if needed. Timer-based refresh via `startRefreshing()`/`stopRefreshing()`.
- **`SentryTheme`** (enum, static properties only) -- Design tokens: colors (`bg`, `cardBG`, `cardHover`, `text`, `brightText`, `muted`, `border`, `danger`, `success`) and dimensions (`popupWidth`, `popupHeight`). Used throughout all views.
- **`PortSentryView`** (View) -- Main popup with header, category filter bar (horizontal scrolling chips), search bar, port list, footer, kill confirmation alert, and kill result toast banner.

## How to Add a Feature

1. **Add model fields** -- If your feature needs new data, add properties to `ListeningPort`. Update the parsing in `scanListeningPorts()` where `ListeningPort` instances are created from lsof output.
2. **Extend the scanner** -- Add state properties to `PortScanner` (they will automatically be observable). Add methods for new logic. If you need different data, modify the `lsof` arguments or add a new data source.
3. **Add UI** -- Create a new view or extend `PortSentryView`. Use `SentryTheme` colors for consistency. For new actions, follow the kill process pattern (confirmation alert + result banner).
4. **Wire into the view** -- Insert new sections in the `VStack(spacing: 0)` body of `PortSentryView`, between `Divider().overlay(SentryTheme.border)` calls.
5. **Rebuild** -- Run `bash build.sh` to compile and package.

## Extension Points

- **New PortCategory cases** -- Add a case to the enum, update `categorize()` with the port ranges, and provide `icon`/`color` values. The category filter chips in `categoryBar` will automatically include it via `categoryCounts`.
- **New actions on ports** -- Follow the `killProcess()` pattern: add a confirmation property (like `killConfirmation`), a result property (like `killResult`), a method that performs the action, an `.alert()` modifier for confirmation, and an `.overlay()` banner for results. Use `SentryTheme.danger` for destructive actions or `SentryTheme.success` for positive outcomes.
- **Extend lsof parsing** -- The `scanListeningPorts()` static method parses lsof's columnar output. Additional columns or different lsof flags can expose more data (e.g., file descriptors, connection state). IPv4 and IPv6 address parsing is handled by `parseAddress()`.
- **SentryTheme colors** -- Add new static color properties to `SentryTheme` for new UI elements. Maintain the dark-theme aesthetic (low-opacity whites for backgrounds, muted colors for secondary text).
- **New filter dimensions** -- Extend `filteredPorts` to support additional filters beyond category and text (e.g., filter by address, by user). Add corresponding state properties and UI controls.
- **Port grouping** -- The port list is currently flat. Add grouping by category (like DiskPulse's `groupedVolumes`) or by process name for an alternative view.

## Conventions

- **Naming**: Types use PascalCase, properties use camelCase. Category enum cases use camelCase (e.g., `webDev`, not `web_dev`).
- **SF Symbols**: All icons use SF Symbols (e.g., `"globe"`, `"server.rack"`, `"cylinder"`, `"xmark.circle.fill"`). The menu bar icon changes between `"antenna.radiowaves.left.and.right"` and its `.slash` variant based on port count.
- **@Observable**: `PortScanner` is the single `@Observable` class. `PortSentryView` receives it via `@Bindable var scanner` for two-way binding on `searchText`, `selectedCategory`, `killConfirmation`, and `killResult`.
- **Theme usage**: All colors and dimensions come from `SentryTheme` static properties. Use `SentryTheme.bg` for backgrounds, `SentryTheme.text`/`brightText` for text, `SentryTheme.muted` for secondary text, `SentryTheme.cardBG`/`cardHover` for list items.
- **Kill process pattern**: SIGTERM first, 500ms grace period on a background queue, then SIGKILL if the process is still alive. Always `scan()` after kill to refresh the list. Show result via a toast banner that auto-dismisses after 2.5 seconds.
- **Category chips**: Horizontal scrolling `HStack` of capsule-shaped buttons. Selected chip uses the category's color as background. Unselected chips use `SentryTheme.cardBG`.
- **Menu bar label**: Shows the total port count as text plus an antenna icon. Keep it minimal.

## Build & Test

Run `bash build.sh` from the repo root. This invokes `swiftc -parse-as-library -O` to compile `PortSentry.swift` into a macOS app bundle with `LSUIElement=true` (no Dock icon). The output is `PortSentry.app`. No Xcode project is needed. Requires macOS 14.0+.
