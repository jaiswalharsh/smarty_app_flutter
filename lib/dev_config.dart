/// Build-time switches for development builds.
///
/// Every switch defaults to production behaviour; a dev build overrides it
/// with `--dart-define`, e.g.
///
///     flutter run --dart-define=SMARTY_LINKING=false
///
/// Compile-time constants, so a disabled feature's code is tree-shaken out of
/// that build and nothing here can be flipped at runtime.
class DevConfig {
  DevConfig._();

  /// Whether setup links the toy to the parent's account (cloud registration
  /// through the `registerDevice` Cloud Function, then the secret written to
  /// the toy). With this off, setup skips the link step, Home never shows
  /// "Almost done — finish setup", and a toy counts as ready on Wi-Fi alone.
  static const bool linkingEnabled =
      bool.fromEnvironment('SMARTY_LINKING', defaultValue: true);

  /// LAN host of a Firebase emulator suite (e.g. `192.168.1.22`), or empty
  /// for the real cloud backend. When set, Auth, Firestore and the
  /// `registerDevice` function all go to the emulators on that host:
  ///
  ///     flutter run --dart-define=SMARTY_EMULATOR_HOST=192.168.1.22
  ///
  /// The emulators have their own accounts: sign up afresh in the app.
  static const String emulatorHost =
      String.fromEnvironment('SMARTY_EMULATOR_HOST');

  /// Whether this build talks to the local emulators ([emulatorHost]).
  static const bool useEmulator = emulatorHost != '';

  /// Emulator ports (firebase/firebase.json).
  static const int authEmulatorPort = 9099;
  static const int firestoreEmulatorPort = 8080;
  static const int functionsEmulatorPort = 5001;

  /// Firebase project id and Cloud Functions region.
  static const String firebaseProjectId = 'smarty-7e350';
  static const String functionsRegion = 'europe-west1';
}
