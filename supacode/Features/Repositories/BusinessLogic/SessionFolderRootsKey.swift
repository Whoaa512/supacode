import Sharing

/// AppStorage key that holds the exact paths of folder-kind repositories that
/// Supacode auto-registered because a dormant session's cwd wasn't already in
/// the repository roster. Persisted in the app's UserDefaults suite so the
/// repos survive relaunch and a forced-folder classification is preserved even
/// when the path is inside a git repo.
nonisolated extension SharedReaderKey where Self == AppStorageKey<[String]>.Default {
  static var sessionFolderRoots: Self {
    Self[.appStorage("sessionFolderRoots"), default: []]
  }
}
