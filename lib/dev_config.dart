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
}
