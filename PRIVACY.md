# Privacy

Codex Usage Dashboard is local-only:

- It reads Codex session logs from %USERPROFILE%\.codex.
- It does not require an API key.
- It does not send analytics, session data, or usage data over the network.
- It writes the generated dashboard snapshot and incremental cache under data/.
- It writes refresh diagnostics under logs/.

The generated files can contain sensitive information, including task titles,
working-directory paths, thread identifiers, token usage, and rate-limit data.
The repository excludes these files through .gitignore.

Before publishing a fork or contribution, inspect the staged file list and diff.
Never commit data/, logs/, raw .jsonl sessions, databases, credentials, or
screenshots made from your real dashboard.
