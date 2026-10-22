# Security policy

Verbatim handles meeting audio, transcripts and API tokens, so security
reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's
[private vulnerability reporting](https://github.com/oliverxuzy-ai/verbatim/security/advisories/new)
instead. Include what you found, how to reproduce it, and which version you
tested. You should hear back within a week.

## Supported versions

Only the latest release gets fixes.

## What Verbatim stores

- Recordings and transcripts: `~/Library/Application Support/Verbatim/Recordings/`
- API keys and tokens: `~/Library/Application Support/Verbatim/secrets.json`
  (readable only by your user)

Nothing is sent anywhere unless you turn on a cloud feature (Soniox, Notion
export, Claude speaker naming, Google Calendar).
