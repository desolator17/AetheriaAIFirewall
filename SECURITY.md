# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email: **security@aetheria.io**

Please include:
- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept (attach as encrypted file if sensitive)
- Affected Aetheria version (`cat /opt/aetheria/VERSION`)
- Your contact details for follow-up

We aim to acknowledge reports within 48 hours and provide a patch timeline within 7 days.

## Coordinated Disclosure

We follow responsible disclosure. Please allow us reasonable time (typically 90 days) to
develop and ship a fix before any public disclosure. We will credit reporters in release
notes unless you prefer to remain anonymous.

## Secrets Policy (for internal engineers)

Per `MASTER_BLUEPRINT.md` Part 17:
- All secrets live in `ansible/group_vars/vault.yml` (ansible-vault encrypted)
- No password, private key, token, or pre-shared secret may appear in any file
  that is not vault.yml — reference vault variables with the `vault_` prefix
- JWT private keys never touch VM disk in plaintext
- The vault password file (`~/.vault_pass`) is never committed to git
- License keys are stored at `/etc/aetheria/license.key` (mode 0600, root) on deployed nodes

## Scope

In-scope for security reports:
- Authentication and session management in the Aetheria API (`src/api/`)
- License validation bypass
- Privilege escalation in the installer or Ansible roles
- Remote code execution in any Aetheria service
- Injection vulnerabilities in the Web UI or API
- WireGuard mesh key exposure

Out of scope:
- Denial-of-service attacks requiring physical access
- Issues in third-party dependencies (report to upstream)
- Social engineering or phishing
