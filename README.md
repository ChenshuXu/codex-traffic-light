# Codex Traffic Light

Codex Traffic Light is a small native macOS menu bar app that shows the combined status of Codex Desktop and Codex tasks in VS Code.

- Red: Codex is waiting for your input.
- Yellow: A task is running.
- Green: A task has finished.
- Gray: No task is available, or the app cannot read the current status.
- Blue unread: A completed reply has not been opened in Codex Desktop or VS Code.

The menu bar shows one dot for the current combined status. Click it to view up to eight recent tasks, with tasks that need input, are still running, or have unread replies listed first. Each row shows the task title and status. Clicking a task returns to its Codex Desktop or VS Code window and attempts to open the exact conversation. Opening a task in either client clears its unread state.

The app can also display the same task list in a small desktop window. You can close and reopen this window from the menu bar or keep it above other windows. Settings control whether the desktop window opens at launch, stays on top, and includes completed tasks. The app remembers the window position.

## Build and Run

Requirements:

- macOS 13 or later
- Apple Command Line Tools

```sh
./build.sh
open "build/Codex Traffic Light.app"
```

The app does not appear in the Dock. Closing the desktop window does not quit the app. Use the quit control at the bottom of the menu bar panel to exit.

The first time you open a VS Code conversation, VS Code may ask whether the Codex extension can open the link. Allow the link and select the option to remember your choice if you want future task clicks to open directly. If the extension route is unavailable, the app still opens the VS Code workspace associated with the task.

## Data and Compatibility

Every two seconds, the app reads the task index, task lifecycle, and writer locks under `~/.codex`. Access is read-only. Task titles come from Codex-generated names. The app checks the local record for the current turn only to determine whether a `request_user_input` call is still unanswered. When you click a task, it reads the session source and working directory to choose the correct destination. It does not display, store, or upload conversation content.

The app reads current unread thread IDs from Codex Desktop's `~/.codex/.codex-global-state.json` and VS Code's local state database. It also connects to the current user's `~/.codex/ipc/ipc.sock` and listens only for `thread-read-state-changed` events, because background completions update persisted unread state without broadcasting that event. IPC fallback state stays in the app's own UserDefaults; the app never writes to Codex or VS Code data.

Codex Desktop and VS Code currently use separate private stdio App Server connections. External apps cannot subscribe directly to both live status streams, so this version uses their shared local state. The reader may need an update if Codex changes its local database or rollout format. See the official [Codex App Server documentation](https://developers.openai.com/codex/app-server).

Known limitation: an approval request that is not written to the local record may temporarily appear yellow. Exact coverage requires an official status stream that both clients can share.
