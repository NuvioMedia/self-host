# Security

## Reporting A Vulnerability

Do not publish suspected vulnerabilities in a GitHub issue. Use GitHub's private
vulnerability reporting for this repository and include affected versions,
reproduction steps, and impact.

## Deployment Checklist

- Run `./nuvio setup`; never reuse the example secret placeholders.
- Expose only ports 80 and 443 publicly.
- Keep `.env`, backups, database files, and storage objects out of Git.
- Keep the service-role key and database credentials on the server.
- Configure SMTP before relying on password recovery email.
- Run `./nuvio doctor` after installs and upgrades.
- Create and test backups before upgrading production instances.
- Treat backup directories as sensitive: they contain account records and files.
- Keep the automatic safety backup until a restore has been verified.
- Keep `ANON_KEY` in clients, but never expose `SERVICE_ROLE_KEY`; maintenance
  RPCs are intentionally executable only by the service role.

The setup enables email auto-confirmation for a low-friction initial deployment.
Operators who configure SMTP should set `ENABLE_EMAIL_AUTOCONFIRM=false`.
