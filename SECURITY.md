# Security policy

## Supported versions

Security updates are applied to the latest release line when practical. Check [`CHANGELOG.md`](CHANGELOG.md) and [releases](https://github.com/dhwani-ris/frappe-mobile-sdk/releases) for current versions.

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | Yes                |
| Pre-1.0 | No (upgrade to 1.x) |

If this table becomes outdated, the latest minor release in the active major line is the intended target for fixes.

## Reporting a vulnerability

**Please do not** open a public GitHub issue for undisclosed security vulnerabilities.

Instead, use one of the following:

1. **GitHub private vulnerability reporting** (preferred if enabled for this repository): open the repository on GitHub and use **Security → Report a vulnerability** (wording may vary by UI). This keeps details private while maintainers investigate.

2. If private reporting is not available, contact the repository maintainers through an appropriate private channel offered by your organization or the [dhwani-ris](https://github.com/dhwani-ris) maintainers, and ask that the message be routed to the `frappe-mobile-sdk` maintainers.

## What to include

To help us assess and fix issues quickly, include when possible:

- A short description of the vulnerability and its impact
- Steps to reproduce, or proof-of-concept, if safe to share
- Affected versions or commit, if known
- Your suggestion for a fix (optional)

We will treat reports confidentially until a fix is ready and coordinated disclosure makes sense.

## Response

- You should receive an acknowledgment after the report is triaged (timeframes depend on maintainer availability).
- We may ask follow-up questions or request a coordinated release timeline.
- After a fix is released, we may credit you in release notes if you wish.

## Scope

This policy applies to the **Frappe Mobile SDK** Flutter package in this repository. Server-side issues (for example in [Frappe Mobile Control](https://github.com/dhwani-ris/frappe_mobile_control)) should be reported to the appropriate project following that project’s security policy.

## Safe harbor

We support responsible disclosure. If you make a good-faith effort to avoid privacy violations, destruction of data, or interruption of services, and give us reasonable time to address the issue before public disclosure, we will not pursue legal action against you for research related to this policy.

## Device-integrity checks: deployment requirements

The optional `FrappeSecurityService` tamper checks have environmental requirements. Misconfiguring the deployment can cause **false positives that block legitimate users**, so review these before enabling a check in production:

### Server time anchor (UTC assumption)

The `serverTimeAnchor` check compares the device clock against the most recent server-supplied `modified` timestamp (read from `doctype_meta.last_ok_cursor`). It assumes the **Frappe server stores `modified` in UTC** — the Frappe default. If a deployment is configured to write local-time timestamps, the anchor is permanently offset by the server's UTC offset and every device will appear to have a rolled-back clock.

- Ensure the server stores timestamps in UTC, **or** exclude `serverTimeAnchor` from `checks` for that deployment.
- The SDK logs a diagnostic (via `sdkLog`) whenever the anchor is more than 24 hours from the device clock — a strong signal of a non-UTC server or a misconfigured server clock rather than a genuine rollback.

### Clock skew tolerance

`serverTimeAnchor` allows a default skew of **15 minutes** (`serverAnchorToleranceMs`). Deployments without reliable NTP commonly drift 6–10 minutes; the default absorbs this. Only tighten the tolerance where NTP is guaranteed.

### Root and mock-location checks

`root` and `mockLocation` rely on platform plugins (`root_checker_plus`, `geolocator`). When a plugin is unavailable the check **fails open** (treated as a pass) so a platform gap can never brick the app; it never fails closed.
