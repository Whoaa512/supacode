import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The "Tasks" menu: the discoverable half of the inbox's chords.
///
/// Store-free, like `SidebarCommands`: every item fires a `FocusedAction`
/// published by `TasksSidebarView`, so on the Worktrees and Agents panels the
/// focused values are simply absent and the whole menu greys out. That absence
/// *is* the tab gate — there is no scene-wide "which panel is showing" the menu
/// could consult without re-deriving it (§2.3 of the keyboard context map).
///
/// The slot chords (⌃1–9) and the next/previous walk are deliberately not
/// repeated here: they are the same `AppShortcut`s the Worktrees menu already
/// lists, and a second copy of "Select Next" that means something else on one
/// panel would be two menu items for one key.
struct TaskCommands: Commands {
  @FocusedValue(\.openTaskCommands) private var openTaskCommands
  @FocusedValue(\.jumpToNextTaskNeedingAttentionAction) private var jumpAction
  @FocusedValue(\.settleTaskAction) private var settleAction
  @FocusedValue(\.snoozeTaskAction) private var snoozeAction
  @FocusedValue(\.pinTaskAction) private var pinAction
  @Shared(.settingsFile) private var settingsFile

  var body: some Commands {
    let overrides = settingsFile.global.shortcutOverrides
    let jump = AppShortcuts.jumpToNextTaskNeedingAttention.effective(from: overrides)
    let settle = AppShortcuts.settleTask.effective(from: overrides)
    let snooze = AppShortcuts.snoozeTask.effective(from: overrides)
    let pin = AppShortcuts.pinTask.effective(from: overrides)
    // Titles follow the open row's own state, read from the one cached
    // structure the reducer's arms branch on — so "Unsettle" can never fire a
    // settle.
    let settleTitle = openTaskCommands?.isSettled == true ? "Unsettle Task" : "Settle Task"
    let pinTitle = openTaskCommands?.isPinned == true ? "Unpin Task" : "Pin Task"

    CommandMenu("Tasks") {
      Button("Jump to Next Task Needing You", systemImage: "hand.raised") {
        jumpAction?()
      }
      .appKeyboardShortcut(jump)
      .help(
        "Open the next task asking for you — skips the ones working away quietly "
          + "(\(jump?.display ?? "none"))"
      )
      .disabled(jumpAction?.isEnabled != true)
      Divider()
      Button(settleTitle, systemImage: "archivebox") {
        settleAction?()
      }
      .appKeyboardShortcut(settle)
      .help(Self.settleHelp(openTaskCommands, shortcut: settle?.display))
      .disabled(settleAction?.isEnabled != true)
      // One preset, always the same one: a chord cannot open a submenu, and "In
      // an Hour" is the cheapest thing to be wrong about — Wake Now is one
      // right-click away.
      Button("Snooze Task for an Hour", systemImage: "moon.zzz") {
        snoozeAction?()
      }
      .appKeyboardShortcut(snooze)
      .help(Self.snoozeHelp(openTaskCommands, shortcut: snooze?.display))
      .disabled(snoozeAction?.isEnabled != true)
      Button(pinTitle, systemImage: "pin") {
        pinAction?()
      }
      .appKeyboardShortcut(pin)
      .help(
        openTaskCommands?.isPinned == true
          ? "Stop keeping this task at the top of Active (\(pin?.display ?? "none"))"
          : "Keep this task at the top of Active (\(pin?.display ?? "none"))"
      )
      .disabled(pinAction?.isEnabled != true)
    }
  }

  /// A18b in the menu bar: a refused action says why rather than going quiet.
  private static func settleHelp(
    _ commands: TasksSidebarStructure.OpenTaskCommands?,
    shortcut: String?
  ) -> String {
    let chord = shortcut ?? "none"
    guard let commands else { return "Open a task first (\(chord))" }
    if commands.isSettled {
      return "Move this task back to Active (\(chord))"
    }
    return commands.canSettle
      ? "Mark this task wrapped up and move it to the settled tail (\(chord))"
      : "An agent on this task is working or waiting on you — answer it first"
  }

  private static func snoozeHelp(
    _ commands: TasksSidebarStructure.OpenTaskCommands?,
    shortcut: String?
  ) -> String {
    let chord = shortcut ?? "none"
    guard let commands else { return "Open a task first (\(chord))" }
    return commands.canSnooze
      ? "Park this task for an hour; it comes back where it is now (\(chord))"
      : "This task is waiting on you — snoozing it would surface it again immediately"
  }
}

private struct OpenTaskCommandsKey: FocusedValueKey {
  typealias Value = TasksSidebarStructure.OpenTaskCommands
}

private struct JumpToNextTaskNeedingAttentionActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct SettleTaskActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct SnoozeTaskActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct PinTaskActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  /// What the open row can do, for the two items whose titles flip. Published
  /// as a value rather than folded into the actions because a `FocusedAction`
  /// carries behaviour, not a label — the `openActionSelection` precedent.
  var openTaskCommands: TasksSidebarStructure.OpenTaskCommands? {
    get { self[OpenTaskCommandsKey.self] }
    set { self[OpenTaskCommandsKey.self] = newValue }
  }

  var jumpToNextTaskNeedingAttentionAction: FocusedAction<Void>? {
    get { self[JumpToNextTaskNeedingAttentionActionKey.self] }
    set { self[JumpToNextTaskNeedingAttentionActionKey.self] = newValue }
  }

  var settleTaskAction: FocusedAction<Void>? {
    get { self[SettleTaskActionKey.self] }
    set { self[SettleTaskActionKey.self] = newValue }
  }

  var snoozeTaskAction: FocusedAction<Void>? {
    get { self[SnoozeTaskActionKey.self] }
    set { self[SnoozeTaskActionKey.self] = newValue }
  }

  var pinTaskAction: FocusedAction<Void>? {
    get { self[PinTaskActionKey.self] }
    set { self[PinTaskActionKey.self] = newValue }
  }
}
