# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 0.6.0
### Changed
- Overhaul all APIs.

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
