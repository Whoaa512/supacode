# Autoresearch Ideas

- Move periodic scrollback save (timer in WorktreeTerminalManager) off MainActor to avoid blocking the main thread with file I/O during each persist tick.
