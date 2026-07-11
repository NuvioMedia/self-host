# Security

## Reporting A Vulnerability

Do not publish suspected vulnerabilities in a GitHub issue. Use GitHub's
private vulnerability reporting for this repository and include the affected
version, reproduction steps, and impact.

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

Email auto-confirmation is enabled by default. To use verification, password
recovery, and email-change messages, configure the `SMTP_*` settings in `.env`,
set `ENABLE_EMAIL_AUTOCONFIRM=false`, and run `./nuvio up`.

## Secrets

`./nuvio setup` writes generated secrets to `.env` with file mode `0600`. Do
not reuse secrets between deployments. Anyone with the service-role key or
database credentials can bypass normal account-level access controls.

## API Access

Account and synchronization RPCs require an authenticated user session.
Maintenance helpers are restricted to the service role. Public endpoints are
limited to health checks, avatar catalog reads, and TV login initiation and
polling.
