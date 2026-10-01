import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dev_config.dart';
import 'home_tab.dart';
import 'screens/conversations/conversations_tab.dart';
import 'settings_tab.dart';
import 'providers/user_context_provider.dart';
import 'utils/theme_provider.dart';
import 'services/ble_manager.dart';
import 'services/ble_service.dart';
import 'screens/auth/login_page.dart';

void main() async {
  // Ensure Flutter is initialized
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything else touches Bluetooth (iOS reads the options once).
  await BleService.configureBeforeFirstUse();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _connectBackend();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        // Not lazy: it follows the toy from the start — keeps the account's
        // copy of the child's profile and pushes unsent edits on reconnect.
        ChangeNotifierProvider(
          create: (_) => UserContextProvider()..init(),
          lazy: false,
        ),
      ],
      child: const MyApp(),
    ),
  );
}

/// Points Auth and Firestore at the local emulators when this is an emulator
/// build ([DevConfig.useEmulator]); must run before either is first used.
///
/// Accounts and data don't carry over between the cloud and the emulators,
/// so when the backend differs from last launch the Firestore cache is
/// cleared and a remembered sign-in is dropped: the parent signs in (or up)
/// again, instead of the app failing every request with a session the other
/// backend has never heard of.
Future<void> _connectBackend() async {
  const String backend = DevConfig.useEmulator
      ? 'emulator:${DevConfig.emulatorHost}'
      : 'cloud';
  if (DevConfig.useEmulator) {
    try {
      await FirebaseAuth.instance.useAuthEmulator(
          DevConfig.emulatorHost, DevConfig.authEmulatorPort);
      FirebaseFirestore.instance.useFirestoreEmulator(
          DevConfig.emulatorHost, DevConfig.firestoreEmulatorPort);
      debugPrint('Backend: emulators on ${DevConfig.emulatorHost}');
    } catch (e) {
      debugPrint('Backend: could not switch to the emulators: $e');
    }
  }
  try {
    const String key = 'smarty_backend';
    final prefs = await SharedPreferences.getInstance();
    final String last = prefs.getString(key) ?? 'cloud';
    if (last != backend) {
      debugPrint('Backend: changed ($last -> $backend)');
      // Firestore's offline cache would otherwise mix the two backends'
      // documents (it is keyed by project, not host). Must run before any
      // other Firestore call — nothing has touched it yet.
      try {
        await FirebaseFirestore.instance.clearPersistence();
      } catch (e) {
        debugPrint('Backend: could not clear the Firestore cache: $e');
      }
      if (FirebaseAuth.instance.currentUser != null) {
        await FirebaseAuth.instance.signOut();
      }
    }
    await prefs.setString(key, backend);
  } catch (e) {
    debugPrint('Backend: could not check the last backend: $e');
  }
}

// No app-wide BLE snackbars: connection changes show in place on the Home and
// Settings cards, which render from BleManager.phase.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smarty Toy',
      debugShowCheckedModeBanner: false,
      themeMode: Provider.of<ThemeProvider>(context).themeMode,
      theme: Provider.of<ThemeProvider>(context).lightTheme,
      darkTheme: Provider.of<ThemeProvider>(context).darkTheme,
      home: SplashScreen(),
    );
  }
}

// Add a fun splash screen
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  
  @override
  void initState() {
    super.initState();
    
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    
    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.elasticOut,
      ),
    );
    
    // Start animation and navigate after it completes
    _controller.forward().then((_) {
      Future.delayed(Duration(milliseconds: 500), () {
        if (!mounted) return;
        final isLoggedIn = FirebaseAuth.instance.currentUser != null;
        final destination = isLoggedIn
            ? MyHomePage()
            : LoginPage();
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) => destination,
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: Duration(milliseconds: 800),
          ),
        );
      });
    });
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF4169E1), Color(0xFF83A8F0)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: _scaleAnimation,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 16,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Image.asset(
                      'assets/images/icon.png',
                      width: 80,
                      height: 80,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 24),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Opacity(
                    opacity: _controller.value,
                    child: Transform.translate(
                      offset: Offset(0, 20 * (1 - _controller.value)),
                      child: Text(
                        "Smarty",
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  );
                },
              ),
              SizedBox(height: 8),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Opacity(
                    opacity: _controller.value,
                    child: Transform.translate(
                      offset: Offset(0, 20 * (1 - _controller.value)),
                      child: Text(
                        "Your Smart Toy Companion",
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  int _currentIndex = 0;

  static const int _conversationsIndex = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Signed in: start watching for this account's toy. Non-blocking — Home
    // renders from BleManager.phase while the quick probe runs.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(BleManager().watchSavedToy());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Back from the background (or from Settings after turning Bluetooth
      // on / granting permission / forgetting a stale pairing): re-check.
      unawaited(BleManager().watchSavedToy());
    } else if (state == AppLifecycleState.detached) {
      unawaited(BleManager().disconnectAndReset());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Tabs stay mounted (IndexedStack) so their state — e.g. Home's success
      // celebration — survives switching tabs.
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeTab(),
          // Listens only while it is the visible tab.
          ConversationsTab(isActive: _currentIndex == _conversationsIndex),
          SettingsTab(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 8,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
          child: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            items: [
              BottomNavigationBarItem(
                icon: ImageIcon(
                  AssetImage('assets/images/icon.png'),
                ),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.chat_bubble_outline_rounded),
                activeIcon: Icon(Icons.chat_bubble_rounded),
                label: 'Conversations',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.settings_rounded),
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
