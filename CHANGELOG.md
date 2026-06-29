# Changelog

## v1.2.5
- Fix a class of intermittent "Invalid user name or token" failures that could never recover: if the very first submission entered a bad username, the retry only refreshed the token and left the corrupt username in place, so every attempt was rejected. Recovery now escalates to a full credential re-entry (username + token) after a token-only retry still fails
- Authentication no longer gives up after only 3 quick retries inside the first ~15 seconds; the recovery budget and wait window are aligned (up to 5 recovery attempts over 180 seconds), and the run now fails fast with a precise reason when the credential keeps being rejected instead of idling out the remaining wait
- Window logging now records each dialog's size and position, so the otherwise-identical "New version" update prompt and "Invalid user name or token" error can be told apart from the text logs alone (no screenshot needed)

## v1.2.4
- Fix intermittent "Invalid user name or token" authentication failures: credentials are now entered via the clipboard (Ctrl+V) instead of streamed keystrokes, which could drop or reorder characters on the Qt login fields
- The one-time code is now submitted early in its ~29-second validity window (waiting for a fresh TOTP period when little time remains) so it cannot go stale before the server validates it
- Authentication now recovers from any modal dialog (the "Invalid user name or token" error or the "New version" update prompt) by dismissing it and re-submitting with a fresh code, instead of giving up
- Added an opt-in `capture-diagnostics` input (default `false`) that saves screenshots during authentication for debugging; window titles are always logged
- Test workflow now deterministically exercises and asserts the two-window recovery path

## v1.2.3
- Fix intermittent authentication failure where the signing certificate never became available after a successful login attempt

## v1.2.2
- Fix incorrect delay

## v1.2.1
- Replaced fixed wait times with retry loops that proceed as soon as the expected state is reached
- Window initialization now polls until a visible window appears instead of waiting a fixed delay
- Certificate verification now retries for up to 60 seconds instead of waiting a fixed 10 seconds

## v1.2.0
- Handle update dialog that appears when a new version of SimplySign Desktop is detected
- Improved compatibility with earlier versions of SimplySign Desktop
- Script now fails fast when authentication fails or the expected certificate is not found

## v1.1.0
- Update example usage
- Update SimplySignDesktop version to 9.4.3.90

## v1.0.0
- Initial release.
