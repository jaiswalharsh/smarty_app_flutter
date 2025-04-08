# Smarty App Setup

This README guides you through setting up the Smarty App project for different platforms.

## Prerequisites

*   Flutter SDK: Ensure Flutter is installed and configured in your environment. You can download it from the official Flutter website: [https://flutter.dev/docs/get-started/install](https://flutter.dev/docs/get-started/install)
*   Android Studio: Required for building Android apps. Download and install it from: [https://developer.android.com/studio](https://developer.android.com/studio). Make sure to install the Flutter and Dart plugins in Android Studio.
*   Xcode: Required for building iOS apps. Available on macOS via the App Store.
*   CocoaPods: A dependency manager for Swift and Objective-C Cocoa projects. It is needed for managing dependencies in the iOS project. Install it using `sudo gem install cocoapods`.

    *   **Note:** CocoaPods requires Ruby.
    *   For detailed installation instructions, refer to the official CocoaPods guide: [https://guides.cocoapods.org/using/getting-started.html](https://guides.cocoapods.org/using/getting-started.html)

## Android Setup

1.  **Install Android Studio:** If not already installed, download and install Android Studio.
2.  **Configure Android SDK:** Ensure the Android SDK is properly configured in Android Studio.
3.  **Set `ANDROID_HOME` environment variable:** Set the `ANDROID_HOME` environment variable to the location of your Android SDK.
4.  **Accept Android Licenses:** Run `flutter doctor --android-licenses` to accept the necessary Android licenses.
5.  **Verify `android/build.gradle.kts` configuration:**
    *   Repositories: `google()` and `mavenCentral()`
    *   `newBuildDir` and `subprojects` configurations
6.  **Get dependencies:** Run `flutter pub get`
7.  **Build and Run:** Use `flutter run` to deploy the app on an Android device or emulator.

## iOS Setup

1.  **Install Xcode:** If not already installed, download and install Xcode from the Mac App Store.
2.  **Install CocoaPods:** Open the terminal and run `sudo gem install cocoapods`.
3.  **Configure Xcode:** Ensure Xcode is properly configured with your Apple ID and development certificate.
4.  **Verify `ios/Runner.xcodeproj/project.pbxproj` configuration:**
    *   Build settings, target dependencies, and more (see project file for details)
5.  **Get dependencies:** Run `flutter pub get`
6.  **Install iOS dependencies:** Navigate to the `ios` directory and run `pod install`.
7.  **Build and Run:** Use `flutter run` to deploy the app on an iOS device or simulator.
