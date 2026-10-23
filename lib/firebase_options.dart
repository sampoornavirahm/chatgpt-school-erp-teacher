// Placeholder configuration. Run `flutterfire configure` to replace this file
// with the options for the registered Teachers app in your Firebase project.
import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static const currentPlatform = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
    appId: String.fromEnvironment('FIREBASE_APP_ID'),
    messagingSenderId: String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID'),
    projectId: String.fromEnvironment('FIREBASE_PROJECT_ID'),
  );
}
