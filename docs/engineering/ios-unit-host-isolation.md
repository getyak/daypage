# Isolated iOS unit host

`DayPageTests` links the app executable. Its fixtures run after the executable's
entry point, so a fixture Vault override cannot protect production startup.
The unit host must be selected before `DayPageApp` or its stored properties exist.

For Simulator unit builds use Debug with these build settings:

```text
DAYPAGE_QA_BUNDLE_SUFFIX=.qa-unit
DAYPAGE_UNIT_TEST_CONDITIONS=DAYPAGE_ISOLATED_TEST_HOST
CODE_SIGN_ENTITLEMENTS=
CODE_SIGNING_ALLOWED=NO
```

Do not override `SWIFT_ACTIVE_COMPILATION_CONDITIONS` globally. Swift packages
have their own conditions (including Crypto's platform selection); only the App
and test target Debug settings add the explicit unit-host condition to their
inherited conditions. The QA-only Keychain probe is omitted from ordinary builds.
The app entry point requires the exact QA bundle identity and XCTest injection.
Missing configuration stops startup. A `.qa-unit` identity without the unit-host
condition also stops instead of falling back to the real app.

The unit host displays an empty Scene. It does not initialize authentication,
Vault maintenance, migrations, analytics, Sentry, background tasks or Watch.
Tests that need a Kit hook or provider must install their own fixture. Passing
these tests does not verify production startup or those integrations.

The bundle suffix appears before nested Widget and Watch identifiers. The Watch
companion identifier follows the same main-app identity. Inspect the processed
Info.plists, actual compiler arguments, test-host path and effective entitlements
before executing tests; source configuration alone is insufficient evidence.

Simulator signing alone is not sufficient Keychain isolation. In Debug iOS
builds, the exact `.qa-unit` and `.qa-ui` app identities use distinct auth/API
Keychain service names. All helper reads, writes and deletes use that same
namespace. Before credential tests, use a unique dummy account to confirm the
effective QA service and retain any signing/Keychain failure as unverified.
Never probe or remove a production credential to demonstrate isolation.

The App and Widget also select dedicated preference-suite names for their
exact Debug QA identities. Removing App Group entitlements alone does not prove
that a named `UserDefaults` suite cannot resolve on Simulator. QA UI runs pass
the existing `-qaForceLocalVault` launch argument before production startup;
their local Vault and defaults belong to the dedicated app sandbox.

UI verification uses a separate `.qa-ui` identity, without the unit-host compile
condition, so it exercises real startup. Use an isolated sandbox, no personal
iCloud or App Group entitlement, and no real service credentials. Production
startup, real service acceptance and user-feature rounds remain separate gates.
