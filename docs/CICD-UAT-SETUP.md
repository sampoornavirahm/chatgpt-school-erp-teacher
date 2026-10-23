# One-time Android UAT release setup

Create a GitHub Actions environment named `uat` in this repository. Add these environment variables: `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_TESTER_EMAILS`, `GOOGLE_SERVER_CLIENT_ID`, and this app's Firebase app ID (`FIREBASE_TEACHERS_APP_ID). Add these environment secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `FIREBASE_SERVICE_ACCOUNT_JSON`, and `FIREBASE_API_KEY`.

Create one Android keystore and keep it stable across releases. The Firebase service account needs Firebase App Distribution Admin access for this Firebase project. Never commit the keystore, service-account JSON, or real school data. A successful push to `main` validates the app, builds a versioned signed UAT APK, stores it as a workflow artifact, and sends it to the configured Firebase testers. Android requires the tester to approve installation of each APK update.
