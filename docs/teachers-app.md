# Teacher mobile app guide

The Teacher app works with a local school Hub over the school's Wi-Fi. A hosted Teacher sign-in exists for backend setup and notification registration, but hosted Teacher record access is not implemented; pair the phone with the local Hub to use teaching workflows.

## Connect your phone

1. Ask the school administrator to enable the Hub's secure local-network connection and create a one-use pairing code in **Hub & backups** on the desktop.
2. Connect the phone to the school's Wi-Fi and open the Teacher app.
3. Choose **Connect your school**, enter the pairing code, and complete device pairing.
4. Sign in with the Teacher account the school administrator created for you. The Hub checks your role, device and class assignments.

The code is single-use and expires after five minutes. If it expires, ask the administrator for a new one. Do not send the code to anyone else.

## Use the app

- **Overview:** check your assigned classes, upcoming work and school updates.
- **Attendance:** choose the date and class, mark attendance, and save. If the Hub is temporarily unavailable, the app stores the draft on the phone and shows it in the sync queue.
- **Homework:** review assigned work and due dates.
- **Draft marks:** enter marks for an open exam. The Hub checks the exam, student, mark range and revision when the draft syncs; a stale or invalid draft needs review.
- **Notices:** read published school announcements. The notice inbox is the source of the full message; a push notification, when enabled, only says that a new school notice is available.

The app retries queued work while it is open and connected. Open the app after returning to school Wi-Fi or use the sync status/retry action if work remains queued. Sign out only after pending work has had a chance to sync.

## Notifications and privacy

Push notifications are optional. Choose **Enable notifications** in the app and allow the device permission. Firebase must be configured by the service owner first. If push is unavailable, open **Notices** and sync with the Hub to get updates. Analytics, crash reports, performance traces and in-app campaign data remain off until the user opts in in the app.

The phone cache is separated by school and user, but it is not encrypted by this implementation. Use a device passcode and operating-system storage protection. Do not share your login or use another person's account.

## Help

If sign-in fails, check the account type with the school office. If class lists are missing, ask the administrator to assign you to the class/section. If a notice or attendance item looks old, reconnect to the school's Wi-Fi, open the app and allow it to sync.
