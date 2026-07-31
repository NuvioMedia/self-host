# Connect Nuvio Apps

Use this guide when building a Nuvio app that connects to your self-hosted
server. Every app must use the Backend URL and Publishable key from the same
deployment. From your Nuvio Self-Hosted directory, run:

```sh
./nuvio credentials
```

Replace `<BACKEND_URL>` and `<PUBLISHABLE_KEY>` below with the printed values.
For a phone, TV, or another physical device, use your public HTTPS address
without a trailing slash. Never put the service-role key, Supabase secret key,
database password, or Studio password in an app.

The public avatar bucket URL is:

```text
<BACKEND_URL>/storage/v1/object/public/avatars
```

## Choose Your App

| App source | File to edit |
| --- | --- |
| `NuvioMedia/NuvioTV` | Root `local.properties` |
| `NuvioMedia/NuvioMobile` | Root `local.properties` or build environment variables |
| `NuvioMedia/NuvioDesktop` | Root `local.properties` or build environment variables |
| `NuvioMedia/NuvioWeb` | Root `local.properties`; included in Web, Tizen, and webOS builds |

## Android TV

Open the `NuvioTV` project and add these values to its root
`local.properties` file:

```properties
SELF_HOSTED=true
NUVIO_SUPABASE_URL=<BACKEND_URL>
NUVIO_SUPABASE_ANON_KEY=<PUBLISHABLE_KEY>
NUVIO_SUPABASE_FALLBACK_URL=
NUVIO_REALTIME_SYNC_ENABLED=false
AVATAR_PUBLIC_BASE_URL=<BACKEND_URL>/storage/v1/object/public/avatars
```

If you build a debug APK, copy the same settings to `local.dev.properties`.
That file takes priority over `local.properties`, so remove any values that
point to a different backend.

`SELF_HOSTED=true` gives your TV build direct email and password sign-in. This
self-hosted mode does not use QR sign-in and does not need
`TV_LOGIN_WEB_BASE_URL`.

Rebuild the client after changing the file:

```sh
./gradlew :app:assembleFullDebug
```

## Mobile

Open the `NuvioMobile` project and create or update its root
`local.properties` file:

```properties
NUVIO_SUPABASE_URL=<BACKEND_URL>
NUVIO_SUPABASE_ANON_KEY=<PUBLISHABLE_KEY>
NUVIO_SUPABASE_FALLBACK_URL=
NUVIO_REALTIME_SYNC_ENABLED=false
```

These values configure both Android and iOS. You can also provide variables
with the same names in the build environment, but a non-empty value in
`local.properties` takes priority. Avatar URLs come from
`NUVIO_SUPABASE_URL`, so you do not need a separate avatar setting.

Rebuild the Android or iOS app after changing the values.

## Desktop

Open the `NuvioDesktop` project and create or update its root
`local.properties` file:

```properties
NUVIO_SUPABASE_URL=<BACKEND_URL>
NUVIO_SUPABASE_ANON_KEY=<PUBLISHABLE_KEY>
NUVIO_SUPABASE_FALLBACK_URL=
NUVIO_REALTIME_SYNC_ENABLED=false
```

You can also supply the same names as build environment variables. A non-empty
value in `local.properties` takes priority. Avatar URLs come from
`NUVIO_SUPABASE_URL`.

Rebuild the desktop app after changing the values:

```sh
./gradlew :composeApp:packageReleaseDistributionForCurrentOS
```

Realtime is not required for normal synchronization. Keep
`NUVIO_REALTIME_SYNC_ENABLED=false` with the default backend. Set it to `true`
only when the backend was configured with the `realtime` Compose profile.

## Web, Tizen, and webOS

The `NuvioWeb` project provides the browser app and the packaged Samsung Tizen
and LG webOS apps. Open that project, copy the example file, and then set your
backend values:

```sh
cp local.example.properties local.properties
```

Edit `local.properties`:

```properties
SUPABASE_URL=<BACKEND_URL>
SUPABASE_ANON_KEY=<PUBLISHABLE_KEY>
TV_LOGIN_REDIRECT_BASE_URL=https://app.example.com/tv-login
AVATAR_PUBLIC_BASE_URL=<BACKEND_URL>/storage/v1/object/public/avatars
```

Replace `app.example.com` with the address where you host the web app.
`TV_LOGIN_REDIRECT_BASE_URL` must point to its `/tv-login` page and use the same
backend. The avatar setting is optional because the app can derive it from
`SUPABASE_URL`, but setting it explicitly keeps all TV builds consistent.

Build the browser app:

```sh
npm install
npm run build
```

The build writes the selected values to `dist/nuvio.env.js`. Deploy the full
`dist/` directory; do not omit that file.

Build packages for physical TVs from the same configured project:

```sh
npm run package:webos
npm run package:tizen
```

Both packages include the generated `nuvio.env.js`, so you do not need to enter
backend values on the TV. Rebuild and reinstall the package whenever the
values change.

To package Tizen with a properties file stored elsewhere, use:

```sh
npm run package:tizen -- --env-source /absolute/path/to/local.properties
```

## Verify the Connection

Before testing your app, check the backend:

```sh
./nuvio doctor
```

Then check that your rebuilt app can create or sign in to an account, create a
profile, load avatars, and synchronize a change with another app. On NuvioTV,
make sure direct email and password sign-in appears instead of QR sign-in. For
Web TV builds, also test QR sign-in if you configured a matching `/tv-login`
page.
