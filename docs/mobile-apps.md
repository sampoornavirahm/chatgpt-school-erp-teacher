# Flutter mobile apps

`Teachers` and `Parents` are separate Flutter applications. `MobileShared` provides common setup, Hub pairing, secure token storage, offline SQLite, logo, notification controls and Firebase integration. The apps support local School Hub mode for LAN school records and hosted Laravel mode for setup/authentication/FCM. In Phase 7, the hosted Parent app also reads linked student projections and queues parent requests through the Laravel relay. Hosted Teacher access remains setup/sign-in only; teachers use the local Hub pairing workflow.

## Current workflows

### Local School Hub mode

1. On the school Wi-Fi, an administrator enables the Hub's LAN listener and copies a one-use pairing code from **Hub & backups**.
2. Paste that code into the mobile app. It contains the private Hub address, school ID, five-minute enrollment secret and certificate fingerprint. The app pins the certificate and redeems the code once.
3. Sign in using a local account provisioned by the school administrator. Mobile sign-in is restricted to a paired device and matching teacher/parent role.
4. Teachers receive only assigned classes/students and can use Overview, Attendance, Homework, Draft marks and Notices. They can save attendance and marks offline. Parents receive only explicitly linked students and can use Children, Learning, Fees, Notices and Requests to view attendance, timetable, homework, published results, invoices/payments, acknowledge notices and queue a request.
5. The local Hub displays LAN status, paired device metadata, sync counters and open conflicts. It remains the authority for the school record.

### Hosted Laravel mode

The backend setup flow checks `/setup/status`; during trial it allows one-time school/admin setup and marks Google/activation checks as bypassed. A school administrator can create teacher/parent hosted accounts. Outside trial, setup requires Google identity verification and an activation code before access; the dummy activation provider works only in local/testing mode and issues a signed Starter license. The first global operator account is bootstrapped once using a server-only token. Operators create trial school tenants, configure relay credentials and link a hosted parent account only to a student already projected for that school. Billing orders and UPI QR URIs are available through the PHP API, but a purchase/checkout screen is not yet built in the Teacher or Parent app. The approved per-start purchase choice and real Google Mobile Ads placements are also pending.

For hosted parent use, enter the backend's HTTPS API root ending in `/api/v1` and sign in with the selected school ID when the same email exists at multiple schools. The parent receives only the explicitly linked student's last synchronized projection. A manual refresh fetches the current view; the Hub polls the relay and carries any requests back to the school. The app writes a request to its durable local outbox before attempting submission, so a network outage leaves it visible as waiting to send. Cached data is app-private SQLite, partitioned by school and account, and not encrypted by this implementation. The Teacher app still requires the school administrator's local LAN pairing code.

### Offline storage and limits

The Hub sends an account-scoped snapshot of classes/students, attendance, timetable, homework, announcements, exams/marks, fee invoices/payments and linked requests. The app stores it in a school-and-account-specific SQLite file in the app-private directory. Attendance marks, draft exam marks, parent requests and announcement acknowledgements are written to a durable outbox before being reported as queued. Sync uses bounded batches, idempotent Hub responses, exponential retry delay, a foreground retry timer and manual retry. Draft marks include the last known revision; the Hub sends stale drafts into conflict review instead of silently replacing a newer mark. Parent request and notice-ack commands are checked against the linked child and notice scope on the Hub.

The mobile SQLite cache is not encrypted by this implementation; use OS device encryption and screen lock. Caches are separated by school/account, but a compromised process with access to app files can still inspect or alter them. On upgrade, the app copies a prior Phase 4 cache snapshot only if the secure cached identity still matches the active user and school; pending operations are additionally filtered by school, user and device. The product owner approved retaining current-session data on devices and keeping prior sessions archived for on-demand access; the cache already remains after sign-out. We treat “session” as an academic session here, but the app/relay has no academic-session key or archive retrieval route yet, so that workflow needs a later schema/API/UI increment. Retry is foreground-only; background retry and connectivity-triggered scheduling remain open product decisions. Hosted parent cache refresh requires a working backend; the Hub relay runs on the configured polling interval and parent requests may therefore take a few minutes to reach the school.

Server bearer tokens are stored with `flutter_secure_storage`; setup passwords and Google ID tokens stay in memory for their request. Analytics, Crashlytics, Performance, Remote Config and In-App Messaging collection starts off and requires user opt-in. Events are generic; names, emails, student records and message content are not included. The A/B-testable Remote Config setting `show_welcome_card` affects presentation only and cannot change authorization or activation.

FCM permission is requested when the user taps **Enable notifications**. On iOS the app waits briefly for APNs readiness, then registers a Firebase Installation ID (FID), and later revokes it through the backend. The backend stores an encrypted FID and a one-way lookup hash. Foreground notification UI shows a generic update message; FCM payloads must not contain student information. The backend can send a generic setup test after Firebase server credentials are configured. A newly published notice detected in a successful relay update queues a generic push for parents explicitly linked to the affected student. The full message remains in the authenticated Notices screen; an unavailable push service does not stop relay sync. Previously opted-in users re-register after signing in again.

## Prepare the Flutter projects

Flutter 3.47.7 and Dart 3.13.5 are installed at `/Users/jcob1289/Developer/flutter-sdk`; Temurin Java 17 and the Android SDK are also installed. Android API 36 and build tools 36.0.0 are configured. Android SDK licenses have been accepted. Both debug APKs build successfully; all three Flutter packages pass analysis; the shared tests cover first launch, storage restart/account isolation, simulated network recovery and revoked-device handling. Android emulation and iOS builds were skipped at the user's request. Firebase CLI 15.0.0 and FlutterFire CLI 1.4.1 are installed; the FlutterFire executable is on the zsh login PATH.

Debug APK outputs:

- `Teachers/build/app/outputs/flutter-apk/app-debug.apk`
- `Parents/build/app/outputs/flutter-apk/app-debug.apk`

These are local debug builds, not signed releases. Full Xcode is not installed, so the accepted Xcode license cannot be applied yet and iOS builds cannot run. CocoaPods is also not installed; complete Xcode setup before installing it and building either iOS target.

From the project root, resolve packages if manifests change:

```sh
cd MobileShared && flutter pub get
cd ../Teachers && flutter pub get
cd ../Parents && flutter pub get
```

Both apps already have generated `android/` and `ios/` platform directories. The bootstrap script remains available for a future clean checkout and refuses to overwrite existing scaffolding. Each app depends on `MobileShared` by local path.

## Configure Google and Firebase

1. Create one Firebase project and register separate Android/iOS apps for `Teachers` and `Parents`. Use each app's generated application IDs. Register Android signing fingerprints and iOS bundle IDs.
2. Sign in with the Google account that administers the Firebase project using `firebase login`. From each app folder run `flutterfire configure --platforms=android,ios`. It replaces the placeholder `lib/firebase_options.dart` and writes platform configuration. Keep each app matched to its own Firebase app registration.
3. Configure Google OAuth platform clients. Set the server/web client ID as `GOOGLE_SERVER_CLIENT_ID` at Flutter build time and the same audience as `GOOGLE_OAUTH_CLIENT_ID` in PHP. Set `GOOGLE_CLIENT_ID` at build time if the platform needs an explicit native client ID. Never put a client secret in either app.
4. In Firebase Console, enable Analytics, Cloud Messaging, Crashlytics, Remote Config, In-App Messaging and Performance Monitoring. Configure the iOS APNs key and notification capabilities before expecting iOS push to work.
5. For Remote Config/A/B Testing, define `show_welcome_card` as a boolean. Experiments may change that visual preference only. A/B Testing and In-App Messaging depend on Analytics consent in this app.
6. App Distribution is a release/CI step through the Firebase CLI, not a runtime Flutter dependency. Distribute signed Android APK/AAB or iOS IPA builds to tester groups after signing is configured.

Firebase project IDs, OAuth client IDs, APNs credentials and service-account JSON are not fabricated or committed. The CLI tools are installed, but Firebase is skipped until a project is selected and generated project configuration is present. Background FCM delivery requires the native configuration and push capabilities generated/configured for each platform.

The Firebase project display name `testproject1` and web app display name `testapp1` are recorded as owner-provided labels; the project ID, native app IDs and generated FlutterFire config still need verification. Firebase CLI authentication and project lookup failed during this phase, so no live Firebase configuration was generated. See the [Firebase setup guide](user-guides/firebase-setup.md) for the pending owner steps and free-tier checks.

## Run and build

Run the backend, then from the target app folder:

```sh
flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-oauth-client-id>
```

Enter `http://127.0.0.1:8000/api/v1` in the iOS simulator or `http://10.0.2.2:8000/api/v1` in the Android emulator. Plain HTTP is accepted only for these local development hosts; school servers must use HTTPS.

After platform scaffolding, signing and Firebase setup, use Flutter's Android or iOS release build commands. iOS archive/signing requires full Xcode and an Apple developer signing setup. Firebase CLI App Distribution delivers signed builds but does not replace signing or platform registration. The local Firebase CLI is installed, but no Google/Firebase account or project is configured. Trial mode skips Google-account and server-activation validation; this does not configure Firebase analytics or push delivery.

## Firebase data boundaries

- Analytics: fixed generic `mobile_app_open` event, no user ID or event parameters.
- Crashlytics: off by default; consent controls uncaught error reporting.
- Performance Monitoring: consent-gated `school_api_request` traces without URL/path attributes.
- Remote Config/A/B Testing: `show_welcome_card` only.
- In-App Messaging: generic `mobile_home_opened` trigger.
- FCM: Firebase Installation IDs are encrypted at rest and indexed by a one-way hash; test push content is fixed and contains no school/student data.
- App Distribution: operator-driven signed builds; no runtime dependency.

Android manifest metadata and iOS `Info.plist` defaults disable FCM auto-init and Analytics, Crashlytics, Performance and advertising/IDFV collection until the app explicitly enables the relevant consent-gated features. FCM installation IDs remain enabled because push registration is an explicit user action.
