# Firebase setup and operations

Firebase is optional. The local Hub and app inboxes must continue working if Firebase is absent or unreachable. The Firebase Android registrations are supplied to release builds through the `uat` GitHub environment.

## Connect the mobile apps

1. In Firebase Console, confirm the project ID and register separate Android apps using `com.iqnaut.parents_app` and `com.iqnaut.teachers_app`.
2. In the `uat` GitHub environment, set `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PARENTS_APP_ID`, `FIREBASE_TEACHERS_APP_ID`, and `GOOGLE_SERVER_CLIENT_ID` as variables. Keep `FIREBASE_API_KEY` and the Firebase service-account JSON in secrets.
3. The Android workflows generate a temporary `google-services.json` from those values, apply the Crashlytics and Performance Monitoring Gradle plugins, build the signed APKs, run Firebase Test Lab Robo smoke tests, then distribute passing builds. The generated native configuration is ignored by Git and is not committed.
4. In Firebase Console, enable Analytics, Crashlytics, Performance Monitoring, Remote Config, Cloud Messaging and In-App Messaging for the project. The app collects analytics, crash reports and performance timings only after the user opts in. Push permission remains a separate choice.
5. Configure the backend's Firebase service account separately if the PHP service needs to send push notifications.

## Firebase Test Lab in CI

- Each main-branch UAT build runs one two-minute Robo test on `MediumPhone.arm` / Android 35 for the relevant app. This checks installation, launch and basic screen traversal; it does not sign in or replace manual UAT of school workflows.
- The CI service account needs the Google Cloud project **Editor** role to use Test Lab's default results bucket from `gcloud`. Firebase App Distribution Admin alone is insufficient. This is a broad project role; use a dedicated CI service account and do not reuse a server/runtime identity.
- Test Lab's Spark quota is up to 10 virtual-device test runs and 60 virtual-device test minutes per project per day. If both app repositories release on the same day, they use two of those runs. Keep the project on Spark; do not attach a billing account.
- Firebase Test Lab is scheduled to shut down on September 30, 2027. Its announced replacement, Google Cloud Developer Device Platform, requires billing, so reassess this test path before that date if Spark-only remains a requirement.

If Firebase CLI cannot list the project, sign in again with the project-owning Google account, confirm the project membership in Firebase Console, then run `firebase projects:list` and repeat FlutterFire configuration. Do not deploy a template until the project and target setting have been reviewed in Console.

## Current app behavior

- **Analytics:** collection is disabled until explicit in-app consent. The app records a generic app-open event without student or account details.
- **Crashlytics:** consent-gated for uncaught error reporting.
- **Performance Monitoring:** consent-gated startup/network monitoring and generic API traces; no student data is intentionally attached.
- **Remote Config/A/B Testing:** the `show_welcome_card` boolean changes a home-screen presentation detail only. Fetching uses a 12-hour release interval and shipped defaults when unavailable. It cannot change access, license or permission rules. A/B experiments require Analytics consent and must only vary this low-risk presentation setting.
- **In-App Messaging:** consent-gated `mobile_home_opened` event; campaigns are authored in Firebase Console.
- **FCM:** users explicitly grant device notification permission. Server payloads contain a generic title/body and a small event type; detailed notice text is fetched from the signed-in app. The in-app Notices page remains the fallback.
- **App Distribution:** the UAT GitHub workflow publishes signed APKs after its Test Lab Robo smoke test passes. Production signing/release remains a separate step.

The PHP service must also be configured with `FIREBASE_PROJECT_ID` and a service-account JSON path outside `Backend/public`. See the [backend hosting guide](backend-hosting.md). A Firebase client setup alone does not enable server push.

## Usage, quotas and cost controls

The product policy is Firebase Spark/free services only. Do not attach a billing account or upgrade to Blaze. Firebase lists Analytics, Cloud Messaging, Crashlytics, In-App Messaging and App Distribution among no-cost products. Remote Config currently includes 100,000 fetch requests per project per day at no cost; stay below that limit. Test Lab's Spark quota is 10 virtual runs and 60 virtual-device test minutes per project per day. Check the official [Firebase pricing plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans), [Remote Config pricing and quotas](https://firebase.google.com/docs/remote-config/pricing) and [Test Lab quotas](https://firebase.google.com/docs/test-lab/usage-quotas-pricing) before changing project settings because quotas and terms can change.

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
- **Test Lab returns 403:** verify the service account belongs to the correct Firebase project and has the required project Editor access for the default results bucket.
