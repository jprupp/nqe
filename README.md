# NQE: Not Quite Erlang

[![Hackage](https://img.shields.io/hackage/v/nqe.svg)](https://hackage.haskell.org/package/nqe)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/jprupp/nqe/blob/master/LICENSE)

NQE is a small Haskell library for concurrency in the style of Erlang/OTP. It
gives you processes that talk to each other through mailboxes, supervisors
that start and watch over them, and publishers that broadcast messages to
subscribers.

Everything is built on [STM](https://hackage.haskell.org/package/stm) and
[unliftio](https://hackage.haskell.org/package/unliftio). It works in `IO` and
in any monad with a `MonadUnliftIO` instance, such as `ReaderT` stacks or
`LoggingT`. It has no C dependencies.

- [API documentation](https://hackage.haskell.org/package/nqe)
- [Changelog](https://github.com/jprupp/nqe/blob/master/CHANGELOG.md)
- [Report a bug](https://github.com/jprupp/nqe/issues)

## Contents

- [Features](#features)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Concepts](#concepts)
- [Usage guide](#usage-guide)
- [Module overview](#module-overview)
- [Things to watch out for](#things-to-watch-out-for)
- [Development](#development)
- [Related projects](#related-projects)
- [License](#license)

## Features

| Area        | What you get                                                                           |
| ----------- | -------------------------------------------------------------------------------------- |
| Processes   | Threads with an inbox, started scoped (`withProcess`) or unscoped (`process`)          |
| Mailboxes   | Unbounded or bounded channels; bounded ones block senders, which gives back-pressure   |
| Messaging   | Asynchronous `send`, synchronous `query` with optional timeouts, selective receive     |
| Supervisors | Four restart-free strategies: kill all, ignore graceful exits, ignore all, or notify   |
| Pub/sub     | Publishers that forward every event to any number of subscribers                       |
| Conduit     | A sink that feeds a conduit stream into a mailbox                                      |

### What is not included

- No distribution: processes live in one Haskell program, not across a network.
- No automatic restarts. Supervisors stop, ignore or report dead children; your
  code decides whether to start them again.
- No process registry or names. Pass `Mailbox` or `Process` values around
  instead.

## Installation

NQE is on [Hackage](https://hackage.haskell.org/package/nqe) and in Stackage
nightly snapshots.

### With Cabal

```cabal
build-depends:
    base
  , nqe
  , unliftio
```

### With Stack

```yaml
# package.yaml
dependencies:
  - nqe
  - unliftio
```

If your resolver does not include NQE, add it to `stack.yaml`:

```yaml
extra-deps:
  - nqe-0.6.7
```

## Quick start

A server that answers `Ping` with `Pong`, and a client that asks it once:

```haskell
import Control.Monad (forever)
import NQE
import UnliftIO

data Pong = Pong deriving Show

newtype Ping = Ping (Listen Pong)

pongServer :: Inbox Ping -> IO ()
pongServer inbox = forever $ do
    Ping reply <- receive inbox
    atomically (reply Pong)

main :: IO ()
main = withProcess pongServer $ \p -> do
    pong <- query Ping p
    print pong -- Pong
```

`withProcess` runs `pongServer` in a new thread, passes its handle to the
function, and stops the thread when the function returns. If the server throws,
the exception is re-thrown in `main`.

## Concepts

| Type            | What it is                                                                 |
| --------------- | -------------------------------------------------------------------------- |
| `Inbox msg`     | Receiving end of a channel. Owned by one process.                          |
| `Mailbox msg`   | Sending end of a channel. Share it with any thread.                        |
| `Process msg`   | A running thread (`Async ()`) together with its `Mailbox`.                 |
| `Listen a`      | An `a -> STM ()` callback, used for replies and subscriptions.             |
| `Supervisor`    | A process that starts, monitors and stops child threads.                   |
| `Publisher msg` | A process that forwards every message it gets to its subscribers.          |

### Channels

`InChan` and `OutChan` are the classes for receiving and sending. `TQueue`,
`TBQueue`, `Inbox`, `Mailbox` and `Process` have instances, so `send`,
`receive` and friends work on all of them. `wrapChannel` turns any channel with
both instances into an `Inbox`.

Mailboxes and inboxes carry a unique identifier. Two of them are equal when
they point at the same channel, and they can be keys in a `HashMap`.

### Synchronous requests

A request carries a `Listen` callback. The receiver runs the callback in `STM`
to deliver its reply. `query` creates the reply variable, sends the request and
waits:

```haskell
data Request = GetCount (Listen Int)

count <- query GetCount counterProcess
```

### Thread linking

`withProcess` and `process` link the new thread to the caller with
`UnliftIO.link`. An exception in the child is re-thrown in the parent as an
`ExceptionInLinkedThread`, so a failing process is never silent.

## Usage guide

### Sending and receiving

```haskell
send msg mailbox                     -- queue a message
msg <- receive inbox                 -- block for the next one
empty <- mailboxEmpty inbox
```

`receiveMatch` takes the first message that a function accepts and leaves the
others in the inbox in their original order:

```haskell
n <- receiveMatch inbox $ \case
    Result n -> Just n
    _ -> Nothing
```

Each of `query` and `receiveMatch` has a version with a timeout in seconds
(`queryS`, `receiveMatchS`) or microseconds (`queryU`, `receiveMatchU`). They
return `Nothing` if the time runs out.

`sendSTM`, `receiveSTM` and `receiveMatchSTM` combine with other `STM` actions
in one transaction.

### Bounded inboxes

```haskell
inbox <- newBoundedInbox 100
```

Senders block while the inbox holds 100 messages. Use `mailboxFullSTM` to drop
messages instead of blocking:

```haskell
atomically $ mailboxFullSTM mbox >>= \full -> unless full (sendSTM msg mbox)
```

### Supervisors

A supervisor runs child actions of type `IO ()` and reacts when one stops,
according to its `Strategy`:

| Strategy         | A child returns normally   | A child throws                               |
| ---------------- | -------------------------- | -------------------------------------------- |
| `KillAll`        | stop everything            | stop everything and re-throw                 |
| `IgnoreGraceful` | ignore it                  | stop everything and re-throw                 |
| `IgnoreAll`      | ignore it                  | ignore it                                    |
| `Notify listen`  | call `listen (child, Nothing)` | call `listen (child, Just exception)`    |

```haskell
withSupervisor KillAll $ \sup -> do
    _ <- addChild sup worker1
    w2 <- addChild sup worker2
    removeChild sup w2           -- stop one child and wait for it
    mainLoop
```

When the supervisor stops, it cancels all its children. Children run in `IO`;
use `withRunInIO` or `toIO` to turn an action in your own monad into a
`ChildAction`.

### Publishers

```haskell
withPublisher $ \pub ->
    withSubscription pub $ \inbox -> do
        publish "hello" pub
        receive inbox >>= putStrLn
```

`withSubscription` creates an unbounded inbox, subscribes it, and unsubscribes
it when the function returns. For a bounded or filtered subscription, call
`subscribe` with your own `Listen` action and `unsubscribe` later.

### Conduit

`conduitMailbox` is a sink that sends every value it receives to a mailbox:

```haskell
runConduit $ sourceHandle stdin .| linesUnboundedAsciiC .| conduitMailbox mbox
```

With a bounded mailbox, a slow consumer slows down the producer.

## Module overview

| Module                               | Contents                                               |
| ------------------------------------ | ------------------------------------------------------ |
| `NQE`                                | Re-exports everything below                            |
| `Control.Concurrent.NQE.Process`     | Inboxes, mailboxes, processes, send, receive, query    |
| `Control.Concurrent.NQE.Supervisor`  | Supervisors, strategies, adding and removing children  |
| `Control.Concurrent.NQE.Publisher`   | Publishers and subscriptions                           |
| `Control.Concurrent.NQE.Conduit`     | `conduitMailbox`                                       |

## Things to watch out for

- A `Listen` action runs inside the receiver's `STM` transaction. Keep it short
  and never let it retry, or the receiver blocks.
- `query` waits forever if the receiver never answers. Use `queryS` or `queryU`
  when the other side might be gone.
- `process`, `publisher` and `supervisor` start threads that you must cancel
  yourself. Prefer the `with` versions, which clean up on exceptions.
- A subscription made with `subscribe` stays until `unsubscribe`. Forgetting to
  unsubscribe leaks the callback and everything it refers to.
- `withSubscription` uses an unbounded inbox. Read from it, or it grows without
  limit.

## Development

```sh
git clone https://github.com/jprupp/nqe.git
cd nqe

stack build                        # build the library
stack test                         # run the tests
stack haddock --no-haddock-deps    # build the API documentation
```

`cabal build` and `cabal test` work too.

`package.yaml` is the source of the package description. Change it rather than
`nqe.cabal`, which [hpack](https://github.com/sol/hpack) generates.

The tests are in `test/Spec.hs` and use [hspec](https://hspec.github.io/).

### Contributing

Pull requests are welcome.

- Keep the style of the code around your change.
- Add tests for the behaviour you change.
- Describe the change in `CHANGELOG.md`, which follows
  [Keep a Changelog](https://keepachangelog.com/en/1.0.0/). Versions follow the
  [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Related projects

- [haskoin-node](https://github.com/jprupp/haskoin-node) is a Bitcoin
  peer-to-peer node built from NQE processes and supervisors.
- [haskoin-store](https://github.com/jprupp/haskoin-store) is a block chain
  indexer that uses NQE for its block store and cache writer.

## License

NQE is released under the
[MIT License](https://github.com/jprupp/nqe/blob/master/LICENSE).
