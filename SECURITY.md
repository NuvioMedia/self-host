# Security

## Report a Vulnerability

If you find a possible vulnerability, do not publish it in a GitHub issue. Use
GitHub's private vulnerability reporting for this repository and include the
affected version, steps to reproduce it, and its possible impact.

## Deployment Checklist

- Run `./nuvio setup` to generate unique deployment secrets.
- Keep `.env`, backups, database files, and Storage files out of Git.
- Expose only ports 80 and 443 on an HTTPS server.
- Keep PostgreSQL and pooler ports bound to localhost or a trusted network.
- Keep `SERVICE_ROLE_KEY`, `SUPABASE_SECRET_KEY`, database credentials, and
  Studio credentials on the server.
- Use the publishable key shown by `./nuvio credentials` in Nuvio clients.
- Run `./nuvio doctor` after installation, configuration changes, and updates.
- Create and verify a backup before updating the deployment.
- Store backups securely; they contain account records and Storage files.
- Keep the automatic safety backup until a restore has been verified.
- Keep the host operating system and Docker Engine updated.

## Email Authentication

New email addresses are confirmed automatically by default. To send email
verification, password recovery, and email-change messages, configure the
`SMTP_*` settings in `.env`, set `ENABLE_EMAIL_AUTOCONFIRM=false`, and run
`./nuvio up`.

## Secrets

`./nuvio setup` writes generated secrets to `.env` with file mode `0600`. Do
not reuse secrets between deployments. Anyone with the service-role key or
database credentials can bypass normal account-level access controls.

## Account Imports

Move your Nuvio Cloud account only from a trusted terminal on your self-hosted
server. The importer sends your password only to Nuvio Cloud sign-in and your
local sign-in service. It never accepts your password as a command argument.
Temporary sign-in tokens and account data are kept in a private directory and
removed when the importer exits.

The Nuvio Cloud publishable key in `.env` is public app configuration. It does
not grant administrative or database access. Never replace it with a
service-role key. An import starts only after a successful sign-in, and the
download contains data from that account only.

If the same email already exists on your server, importing resets its local
password and replaces its app data after you confirm. Cloud password hashes,
signed-in sessions, MFA/passkey secrets, linked devices, PIN hashes, provider
credentials, tracker sign-ins, and login history are not transferred.

## API Access

Account and synchronization requests require a signed-in account. Only the
service role can run maintenance operations. Without signing in, clients can
only check service health, load the public avatar catalog, and start or check a
TV sign-in.
