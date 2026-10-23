# School ERP Teacher App

The Flutter teacher app connects to a school's School Hub and supports offline use. The shared Flutter library is included under `packages/mobile_shared`, so this repository builds on its own.

## Local development

Install Flutter stable (3.47.7 or newer compatible stable), Android Studio command-line tools, and Java 17. From this folder run `flutter pub get`, `flutter analyze`, and `flutter test`. Open `android/` or `ios/` in the corresponding native tool to configure a device build.

## Automated UAT releases

Pushing to `main` validates the app. After the `uat` GitHub environment is configured, pushes also build a signed APK and distribute it through Firebase App Distribution; until then, the distribution job is skipped. The workflow requires one-time environment values and secrets; the release signing key and Firebase service account must only be stored in GitHub Actions secrets. See [UAT release setup](docs/CICD-UAT-SETUP.md).

See [the teacher user guide](docs/teachers-app.md) for the current user flow.
