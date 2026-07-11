# Configure Nuvio Clients

Every Nuvio client must use the Backend URL and Publishable key from the same
self-hosted deployment. Print them from the backend directory:

```sh
./nuvio credentials
```

Use the printed values wherever this guide shows `<BACKEND_URL>` and
`<PUBLISHABLE_KEY>`. Use the public HTTPS URL for physical devices, without a
trailing slash. Never put the service-role key, Supabase secret key, database
password, or Studio password in a client.

The public avatar bucket URL is:

```text
<BACKEND_URL>/storage/v1/object/public/avatars
```

## Client Reference

| Repository | Backend configuration |
| --- | --- |
| `NuvioMedia/NuvioTV` | Root `local.properties` |
| `NuvioMedia/NuvioMobile` | Root `local.properties` or build environment variables |
| `NuvioMedia/NuvioDesktop` | Root `local.properties` or build environment variables |
| `NuvioMedia/NuvioWeb` | Root `local.properties`; included in Web, Tizen, and webOS builds |

## Android TV

In the root of `NuvioTV`, add these values to `local.properties`:

```properties
SELF_HOSTED=true
NUVIO_SUPABASE_URL=<BACKEND_URL>
NUVIO_SUPABASE_ANON_KEY=<PUBLISHABLE_KEY>
NUVIO_SUPABASE_FALLBACK_URL=
NUVIO_REALTIME_SYNC_ENABLED=true
AVATAR_PUBLIC_BASE_URL=<BACKEND_URL>/storage/v1/object/public/avatars
```

The current Gradle build reads the `NUVIO_SUPABASE_*` names shown above. Debug
builds give `local.dev.properties` precedence for backend values. When building
a debug APK, put the same client settings in `local.dev.properties` and remove
any values for a different backend.

`SELF_HOSTED=true` switches NuvioTV to direct email and password sign-in. A
self-hosted build does not use QR sign-in and does not need
`TV_LOGIN_WEB_BASE_URL`.

Rebuild the client after changing the file:

```sh
./gradlew :app:assembleFullDebug
```

## Mobile

In the root of `NuvioMobile`, create or update `local.properties`:

```properties
NUVIO_SUPABASE_URL=<BACKEND_URL>
NUVIO_SUPABASE_ANON_KEY=<PUBLISHABLE_KEY>
NUVIO_SUPABASE_FALLBACK_URL=
NUVIO_REALTIME_SYNC_ENABLED=true
```

These values configure both Android and iOS. The build also accepts variables
with the same names from the environment, but a non-empty value in
`local.properties` takes precedence. Avatar URLs are derived from
`NUVIO_SUPABASE_URL`, so no separate avatar setting is needed.

Rebuild the Android or iOS app after changing the values.

## Desktop

In the root of `NuvioDesktop`, create or update `local.properties`:

```properties
NUVIO_SUPABASE_URL=<BACKEND_URL>
NUVIO_SUPABASE_ANON_KEY=<PUBLISHABLE_KEY>
NUVIO_SUPABASE_FALLBACK_URL=
NUVIO_REALTIME_SYNC_ENABLED=true
```

The same names can be supplied as build environment variables. A non-empty
value in `local.properties` takes precedence. Avatar URLs are derived from
`NUVIO_SUPABASE_URL`.

Rebuild the desktop app after changing the values:

```sh
./gradlew :composeApp:packageReleaseDistributionForCurrentOS
```

## Web, Tizen, and webOS

`NuvioWeb` is the shared source for the browser app and the packaged Samsung
Tizen and LG webOS apps. In the root of `NuvioWeb`, copy the example file and
then set the backend values:

```sh
cp local.example.properties local.properties
```

Edit `local.properties`:

```properties
SUPABASE_URL=<BACKEND_URL>
SUPABASE_ANON_KEY=<PUBLISHABLE_KEY>
AVATAR_PUBLIC_BASE_URL=<BACKEND_URL>/storage/v1/object/public/avatars
```

Self-hosted Web, Tizen, and webOS builds use direct email and password sign-in,
so no TV login redirect URL is needed. The avatar setting is optional because
the client can derive the URL from `SUPABASE_URL`, but setting it explicitly
keeps all TV builds consistent.

Build the browser app:

```sh
npm install
npm run build
```

The build writes the selected values to `dist/nuvio.env.js`. Deploy the full
`dist/` directory; do not omit that file.

Build packages for physical TVs from the same configured checkout:

```sh
npm run package:webos
npm run package:tizen
```

Both packages include the generated `nuvio.env.js`, so they do not need runtime
backend variables on the TV. Rebuild and reinstall the package whenever these
values change.

To package Tizen with a properties file stored elsewhere, use:

```sh
npm run package:tizen -- --env-source /absolute/path/to/local.properties
```

## Verify the Connection

Before testing a client, check the backend:

```sh
./nuvio doctor
```

Then confirm that the rebuilt client can create or sign in to an account,
create a profile, load avatars, and synchronize a change between two clients.
For self-hosted TV clients, confirm that direct email and password sign-in is
available.
