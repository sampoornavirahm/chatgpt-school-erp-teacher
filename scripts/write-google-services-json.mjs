import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

const required = (key) => {
  const value = process.env[key]?.trim();
  if (!value) throw new Error(`Missing required environment variable: ${key}`);
  return value;
};

const config = {
  project_info: {
    project_number: required('FIREBASE_MESSAGING_SENDER_ID'),
    project_id: required('FIREBASE_PROJECT_ID'),
  },
  client: [
    {
      client_info: {
        mobilesdk_app_id: required('FIREBASE_APP_ID'),
        android_client_info: {
          package_name: required('ANDROID_APPLICATION_ID'),
        },
      },
      oauth_client: [
        {
          client_id: required('GOOGLE_SERVER_CLIENT_ID'),
          client_type: 3,
        },
      ],
      api_key: [{ current_key: required('FIREBASE_API_KEY') }],
    },
  ],
  configuration_version: '1',
};

const output = resolve('android/app/google-services.json');
await mkdir(dirname(output), { recursive: true });
await writeFile(output, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
console.log('Generated Android Firebase build configuration.');
