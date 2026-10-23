# Firebase setup and operations

Firebase is optional. The local Hub and app inboxes must continue working if Firebase is absent or unreachable. Current app configuration files are placeholders; the labels `testproject1` and `testapp1` supplied by the owner are display names, not verified Firebase project/app IDs. The project IDs, Android registrations, service-account access and generated app configuration still need to be connected.

## Connect the mobile apps

1. Sign in to the Firebase account that owns the project. Confirm its actual project ID in Project settings; do not use its display name as the ID.
2. Register separate Android apps for Teachers and Parents using each app's Android application ID. Keep Android registration and credentials distinct by app. iOS setup is intentionally not part of this phase.
3. From each app directory, run FlutterFire configuration for Android and select the real project. For example:

   ```sh
   cd Teachers
   flutterfire configure --project <firebase-project-id> --platforms android
   cd ../Parents
   flutterfire configure --project <firebase-project-id> --platforms android
   ```

   The command replaces each app's placeholder `firebase_options.dart` and adds native Android Firebase configuration. Do not commit service-account JSON or OAuth client secrets. The Firebase client API key is public app configuration; do not use it as a server secret.

4. In Firebase Console, enable Analytics, Cloud Messaging, Crashlytics, Performance Monitoring, Remote Config, In-App Messaging and A/B Testing as needed. Set Android Crashlytics/Performance Gradle plugin requirements if FlutterFire asks for them and build a fresh debug APK to verify initialization.
5. In each mobile app, opt in to diagnostics/analytics when prompted. Push permission is requested separately when the user selects **Enable notifications**. To send server notifications, separately configure the PHP service account in the backend.

If Firebase CLI cannot list the project, sign in again with the project-owning Google account, confirm the project membership in Firebase Console, then run `firebase projects:list` and repeat FlutterFire configuration. Do not deploy a template until the project and target setting have been reviewed in Console.

## Current app behavior

- **Analytics:** collection is disabled until explicit in-app consent. The app records a generic app-open event without student or account details.
- **Crashlytics:** consent-gated for uncaught error reporting.
- **Performance Monitoring:** consent-gated generic API traces; no student data is attached.
- **Remote Config/A/B Testing:** the `show_welcome_card` boolean changes a home-screen presentation detail only. It cannot change access, license or permission rules. A/B experiments require Analytics consent and must only vary this low-risk presentation setting.
- **In-App Messaging:** consent-gated `mobile_home_opened` event; campaigns are authored in Firebase Console.
- **FCM:** users explicitly grant device notification permission. Server payloads contain a generic title/body and a small event type; detailed notice text is fetched from the signed-in app. The in-app Notices page remains the fallback.
- **App Distribution:** an operator release step for signed builds; it is not an app runtime feature. Release signing is not configured yet, so only local debug APKs are available.

The PHP service must also be configured with `FIREBASE_PROJECT_ID` and a service-account JSON path outside `Backend/public`. See the [backend hosting guide](backend-hosting.md). A Firebase client setup alone does not enable server push.

## Usage, quotas and cost controls

The product policy is Firebase Spark/free services only. Do not attach a billing account or upgrade to Blaze for Phase 9. Firebase's current pricing pages list Analytics, Cloud Messaging, Crashlytics, In-App Messaging, App Distribution and A/B Testing among no-cost products. Remote Config allows up to 100,000 fetch requests/day on Spark; requests over that threshold are subject to throttling after the applicable grace period. The project's transition period can vary by when Remote Config was enabled, so check the console rather than assuming a grace deadline. Check the official [Firebase pricing plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans) and [Remote Config pricing and quotas](https://firebase.google.com/docs/remote-config/pricing) before changing project settings because quotas and terms can change.

At least once a month, and before any campaign or experiment:

1. In Firebase Console, open **Project settings → Usage and billing** and confirm the project is still on Spark with no billing account attached.
2. Open the Firebase **Usage and billing dashboard** and review the Remote Config quota progress card against the 100,000 daily free limit. Also review service-specific FCM, Analytics and Crashlytics usage. Confirm all apps target the intended project.
3. Review Remote Config's parameter list and experiment results. Keep only the `show_welcome_card` presentation experiment unless a product/privacy review approves another setting.
4. Review App Distribution testers and uploaded artifacts. Only signed release builds and approved tester emails/groups should be distributed.
5. If usage approaches a published quota, pause experiments/campaigns and reduce unnecessary fetches. Do not upgrade billing to restore usage; the apps retain shipped defaults, use the in-app notice inbox and retry sync when open.

Firebase publishes usage in its console; the school desktop/operator portal does not currently provide a Firebase quota dashboard or remote Firebase configuration UI. Do not enable Cloud Functions, Firebase Storage or Firestore for this phase. PHP remains the server authority; no Firestore relay or Firebase Security Rules were added, so there is no Firestore access surface to test.

## Official setup references

- [Add Firebase to Flutter](https://firebase.google.com/docs/flutter/setup)
- [Cloud Messaging for Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/get-started)
- [Crashlytics for Flutter](https://firebase.google.com/docs/crashlytics/flutter/get-started)
- [Remote Config for Flutter](https://firebase.google.com/docs/remote-config/flutter/get-started)
- [In-App Messaging setup](https://firebase.google.com/docs/in-app-messaging/get-started?platform=flutter)
- [Performance Monitoring for Flutter](https://firebase.google.com/docs/perf-mon/flutter/get-started)
- [App Distribution FAQ](https://firebase.google.com/docs/app-distribution/troubleshooting)

## Prepare the Remote Config value

`remoteconfig.template.json` is a local starter template for the existing `show_welcome_card` flag. Review the project, parameter and description in Firebase Console before importing it. Do not add business, authorization, license or student-data settings to this template.

## Troubleshooting

- **Firebase not configured:** the apps stay in local mode; configure native Android apps first.
- **Notification enable fails:** check Android permission, project/app IDs, internet access, backend HTTPS and the server service-account path. Open **Notices** and sync while connected as the fallback.
- **No push received:** use the generic connection test from the school admin screen, verify the device opted in and that a parent is linked to the projected student, then check server logs without recording credentials or notification content.
- **Remote Config unavailable:** the app uses the built-in default and school records remain usable.
- **App Distribution unavailable:** build/sign the release artifact and register the app first; do not distribute the debug APK as a production release.
