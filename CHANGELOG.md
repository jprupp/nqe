# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 0.7.0 - 2026-11-15
### Changed
- Every function runs in plain `IO` (or `STM`, as before) instead of any
  `MonadIO` or `MonadUnliftIO` monad. This breaks backwards compatibility.
  Names and argument orders are the same.
- `conduitMailbox` is a `ConduitT msg o IO ()`.
- A supervisor with the `KillAll` or `IgnoreGraceful` strategy re-throws an
  asynchronous exception that stopped a child wrapped in the new
  `AsyncChildException`. It used to be wrapped in `SyncExceptionWrapper` from
  `unliftio`. Other exceptions are re-thrown unchanged, as before.
- The publisher loop uses `forever`. The workaround of 0.6.7 was only needed
  for `LoggingT`.

### Added
- `AsyncChildException`.
- Tests for timeouts, for `withSubscription` and for a supervised child that
  is cancelled directly.

### Removed
- The dependencies on `unliftio` and `mtl`. The library now depends on `async`
  directly.

### Migrating
- Code that already runs in `IO` needs no change to its calls. If it imported
  `UnliftIO` only to use NQE, it can take `atomically` from
  `Control.Concurrent.STM`, `threadDelay` from `Control.Concurrent`, `cancel`
  and `Async` from `Control.Concurrent.Async`, and exceptions from
  `Control.Exception`.
- Code in another monad has to lift: `liftIO (send msg mbox)`. For the
  functions that take an action (`withProcess`, `process`, `withSupervisor`,
  `withPublisher`, `withSubscription`), run your monad inside the `IO` action.
  With a `ReaderT env IO` stack, for example:

  ```haskell
  env <- ask
  liftIO $ withProcess (\inbox -> runReaderT (server inbox) env) $ \p ->
    runReaderT (client p) env
  ```

- In a conduit over another monad, write `transPipe liftIO (conduitMailbox m)`.
- If you match on `SyncExceptionWrapper` in an exception re-thrown by a
  supervisor, match on `AsyncChildException` instead.
- The behaviour with exceptions is otherwise the same as in 0.6.9: supervisors
  stop their children, and `withSubscription` unsubscribes, with asynchronous
  exceptions blocked uninterruptibly.

## 0.6.9
### Added
- More and better documentation than in version 0.6.8.

## 0.6.8
### Added
- Update documentation everywhere.

## 0.6.7
### Changed
- Use `>>=` explicitly to avoid problems with the LoggingT monad.

## 0.6.6
### Changed
- Simplify author name.
- Bump LTS Haskell.

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
