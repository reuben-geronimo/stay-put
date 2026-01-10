# StayPut

*A macOS cursor confinement utility for gaming (especially notched MacBooks)*

---

## 1. Project Overview

**StayPut** is a modern macOS utility that prevents the mouse cursor from entering macOS system UI regions (menu bar, notch safe area, dock) while gaming. It is designed primarily to fix cursor-related issues in macOS games that do not properly confine the mouse, especially on notched MacBooks.

StayPut is a fork/rewrite inspired by the open-source MouseLock project, modernized for **macOS 26** with a flexible preset system, a clean UI, and notch-aware behavior.

---

## 2. Problem Statement

Many macOS games (e.g., *The Escapists 2*) do not correctly confine the cursor. On notched MacBooks, this causes:
- Cursor reaching the menu bar
- Menu bar dropping down mid-game
- Mouse re-entry / coordinate desynchronization
- Missed or inaccurate input

macOS does not provide a global system setting to prevent this. StayPut solves the problem at the user-space level.

---

## 3. Licensing & Legal

- Original project license: **MIT License**
- StayPut may:
  - Fork, modify, rename, and redistribute the code
  - Add new features and UI
  - Be distributed as a standalone app
- **Requirement:**
  - Preserve the original MIT license and copyright notice
  - Include the LICENSE file in the repo and app bundle

---

## 4. Language & Platform Decisions

### Chosen Stack
- **Swift (only)**
- SwiftUI / AppKit for UI
- Quartz / CoreGraphics for mouse control

### Explicit Decisions
- Remove shell scripts
- Replace all shell-based logic with Swift-native implementations
- Target macOS 26+ behavior and APIs

---

## 5. Core Concept: Presets

StayPut replaces hard-coded behavior with a **data-driven preset system**.

### Preset Model
Each preset contains:
- `id: UUID`
- `name: String`
- `enabled: Bool`
- `scope`
  - `Always`
  - `SpecificApp(bundleIdentifier: String)`
- `lockMode`
  - `MenuBarGuard`
  - `CustomRectangle(width: Int, height: Int)`
- `topPadding: Int` (MenuBarGuard only)

---

## 6. Lock Modes

### 6.1 Menu Bar Guard (Default)

Uses `NSScreen.visibleFrame` to automatically exclude menu bar, notch, and dock.
Applies a default **top padding of 10px** (adjustable).

No manual resolution input required.

### 6.2 Custom Rectangle

Allows manual width/height entry for advanced use cases.

---

## 7. Mouse Confinement Strategy

**Risk Area:** Mouse event handling

- Use event-driven confinement (no polling)
- Clamp and warp cursor on every mouse-move event
- Do NOT use speed-adaptive bounds

---

## 8. Activation Rules

- Preset activates when enabled AND scope matches
- Specific-app presets override Always
- Deterministic ordering if multiple match

---

## 9. Screen Targeting

- v1: Use main screen
- v2: Detect correct screen per window

---

## 10. Permissions

**Required:**
- Accessibility
- Input Monitoring

Detect missing permissions and guide user to System Settings.

---

## 11. App UX

### Menu Bar Utility
- Lock toggle
- Active preset
- Open Settings
- Quit

### Settings Window
- Preset management
- Lock mode selection
- Permissions status

---

## 12. Architecture

### Models
- Preset
- LockMode
- Scope

### Services
- PresetManager
- MouseLockService
- ScreenBoundsService
- AppDetectionService
- PermissionService
- StatusBarController
- SettingsWindowController

---

## 13. Development Phases

### Phase 1
- Core confinement
- Menu Bar Guard
- Global toggle

### Phase 2
- Presets
- Persistence

### Phase 3
- App binding
- Menu bar controls

### Phase 4
- UX polish
- Optional multi-monitor

---

## 14. Primary Use Case

Preset:
- Escapists 2
- Menu Bar Guard
- Top padding: 10px

---

## 15. Known Limitations

- User-space confinement only
- No kernel-level capture
- v1 main-display assumption

---

## 16. Naming

**StayPut**  
"Keep your cursor where it belongs."

---
