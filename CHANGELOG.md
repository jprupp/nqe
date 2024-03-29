# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 0.6.5
### Fixed
- Don't call `waitAnyCatchSTM` with an empty list.

## 0.6.4
### Fixed
- Import `Control.Monad` to fix `mtl-2.3` issue.

## 0.6.3
### Changed
- Add `publish` and `publishSTM` functions.

## 0.6.2
### Changed
- Change license to MIT.

## 0.6.1
### Changed
- Make it compatible with `newTBQueue` getting `Natural` instead of `Int`.

## 0.6.0
### Changed
- Overhaul entire API in a non-backwards-compatible way.
- Separate read/write from write-only mailbox types.
- Improve documentation.

## 0.5.0
### Added
- `Inbox` type is now comparable for equality.
- Haddock documentation for all functions, types and classes.
- Expose `SupervisorMessage` type alias.
- Expose `Publisher` type alias.

### Changed
- Change `Mailbox` typeclass.
- Simplify PubSub module.
- Replace network features with a single conduit.
- Multiple API changes.

### Removed
- Remove dispatcher functions.

## 0.4.1
### Changed
- Specify different dependencies for test and library.

### Removed
- Remove Cabal file from repository.

## 0.4.0
### Added
- Changelog and semantic versions.
- Raw TCP actors.
- Move to `package.yaml` and `hpack`.
- Type-safe asynchronous messages.
- Supervisors for `MonadUnliftIO` actions.
- Test suite.
- PubSub actor.
- Support for bounded PubSub subscribers.
