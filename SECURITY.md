# Security Policy

## Supported Versions

Durian is in early alpha. Only the latest commit on `main` and the most recent
tagged release receive security fixes. Older releases are not supported.

| Version | Supported |
| --- | --- |
| `main` (latest) | :white_check_mark: |
| Latest tagged release | :white_check_mark: |
| Anything older | :x: |

## Reporting a Vulnerability

Please **do not** open a public issue. Use one of:

- [GitHub private security advisory](https://github.com/julion2/durian/security/advisories/new) — preferred.
- Email the maintainer (address visible in the repo metadata).

**What to expect:**

- Acknowledgement within 3 working days.
- Triage and a rough fix timeline within ~1 week, or a clear "won't fix" with reasoning.
- Critical issues (auth bypass, credential exposure, RCE) are prioritised over feature work.
- Once fixed, a public advisory is published with credit to the reporter unless you prefer to stay anonymous.

This is a side project — best-effort timelines, no enterprise SLA. Thank you for reporting responsibly.

For more on Durian's security model, see [docs/security](https://julion2.github.io/durian/security/).
