# Contributing to Pageglass

Pageglass is an early macOS 14+ / Apple Silicon browser built with Swift, AppKit, and system WebKit. Bug reports and focused pull requests are welcome.

- Explain the problem and include reproduction steps, macOS version, and Pageglass version.
- Use a synthetic or public test page. Do not post passwords, cookies, browsing history, or private captures.
- Keep changes small and dependency-free. Read `AGENTS.md` and `docs/architecture.md` first.
- Run `swift test` and `scripts/build.sh`. For browser behavior or UI changes, run `scripts/smoke.sh` in a logged-in macOS desktop session and inspect the actual app.
- CI checks unit tests and builds; it does not replace desktop interaction testing.
- Private WebKit APIs are restricted to the explicitly documented inspector bridge. Do not weaken TLS, WebKit sandboxing, or capture isolation.

Contributions are made under the project's MIT license.
