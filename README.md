# Today Stack

Today Stack is a native macOS menu-bar app for today’s tasks and recurring habits. It keeps the current day close without adding another full-sized productivity window.

<p align="center">
  <img src="TodayStack/Resources/TodayStackIcon-Source.png" width="128" alt="Today Stack app icon">
</p>

## Features

- Reorder tasks by dragging the task itself.
- Link tasks to habits so completing the task fulfills the habit.
- Switch between active and completed tasks with staggered motion.
- Check habits from a compact colored tile grid above the task list.
- See the current month as a GitHub-style contribution heatmap.
- Increase a day’s heat level by completing multiple tasks linked to the same habit.
- Change habit icons and plan a linked task directly from a habit tile.
- Keep all data locally in human-readable JSON.

## Install

Download the latest `Today-Stack.dmg` from [Releases](https://github.com/its-jovee/today-stack/releases/latest), open it, and drag Today Stack into Applications.

Today Stack requires macOS 14 or later. It lives in the menu bar and intentionally has no regular Dock window.

## Build from source

Open `TodayStack.xcodeproj` in Xcode and run the `TodayStack` scheme. From a shell:

```sh
xcodebuild -scheme TodayStack -configuration Debug -destination 'platform=macOS' build
```

## Local data

The app stores its state in `~/.today-stack/state.json`. An optional external plan is read from `~/.today-stack/today.json`; the app never writes that file.

## Daily plan import

`today.json` accepts only replace mode:

```json
{
  "schemaVersion": 1,
  "date": "2026-08-27",
  "mode": "replace",
  "tasks": [
    { "id": "programming-study", "title": "Programming study", "habitSlug": "programming" }
  ]
}
```

`id` is optional (a stable generated UUID is used when omitted), `title` is required, and `habitSlug` is optional. A slug links a task to the habit with the same slug; unknown slugs leave the task unassociated. Matching IDs keep their completion state. An external agent can update the day with:

```sh
mkdir -p ~/.today-stack && cp sample-today.json ~/.today-stack/today.json
```

Reopen the menu-bar popover to import a changed file. Habit slugs are generated from the initial habit name and remain stable after renaming.

## Tests

```sh
xcodebuild \
  -project TodayStack.xcodeproj \
  -scheme TodayStack \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```
