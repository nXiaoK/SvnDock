## Summary

Describe the problem and the scope of this change.

## Verification

- [ ] `swift build --disable-sandbox`
- [ ] `swift test --disable-sandbox`
- [ ] `swift run --disable-sandbox SvnDockCoreSmoke`
- [ ] Relevant plist files pass `plutil -lint`
- [ ] UI or Finder behavior was verified manually, if applicable

## Safety and compatibility

- [ ] SVN execution does not use a shell
- [ ] Selected paths remain inside their registered working-copy root
- [ ] The Finder extension performs no SVN, network or credential work
- [ ] Logs, fixtures and screenshots contain no private data
- [ ] User-facing changes are reflected in both READMEs
