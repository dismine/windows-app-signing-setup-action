# Changelog

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
