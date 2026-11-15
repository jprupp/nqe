# NQE: Not Quite Erlang

[![Hackage](https://img.shields.io/hackage/v/nqe.svg)](https://hackage.haskell.org/package/nqe)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/jprupp/nqe/blob/master/LICENSE)

NQE is a small Haskell library for concurrency in the style of Erlang/OTP. It
gives you processes that talk to each other through mailboxes, supervisors
that start and watch over them, and publishers that broadcast messages to
subscribers.

Everything is built on [stm](https://hackage.haskell.org/package/stm) and
[async](https://hackage.haskell.org/package/async), and runs in plain `IO` and
`STM`. It has no C dependencies.

- [API documentation](https://hackage.haskell.org/package/nqe)
- [Changelog](https://github.com/jprupp/nqe/blob/master/CHANGELOG.md)
- [Report a bug](https://github.com/jprupp/nqe/issues)

## Contents

- [Why NQE](#why-nqe)
- [Design principles](#design-principles)
- [Features](#features)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Tutorial: a counter service](#tutorial-a-counter-service)
- [Concepts](#concepts)
- [Usage guide](#usage-guide)
- [Module overview](#module-overview)
- [Things to watch out for](#things-to-watch-out-for)
- [Development](#development)
- [Related projects](#related-projects)
- [License](#license)

## Why NQE

Most concurrency bugs come from threads sharing mutable state: two threads
change the same thing, and the result depends on who got there first. Locks
and transactions help, but as a program grows it becomes hard to know which
thread may touch what.

Erlang popularised a different discipline. Each piece of state has one owner,
a *process*. Other code cannot touch that state; it can only send the process
a message and, if it needs an answer, wait for a reply. The process handles one
message at a time, so its state is never seen half-changed. Processes are
grouped under *supervisors* that know what to do when one of them dies, so
failures are handled in one place instead of in every thread.

Haskell already has the raw materials for this: cheap threads, STM and the
`async` package. What it lacks is a shared vocabulary. Every project ends up
writing its own request/reply helpers, its own "run this thread and make sure
it dies with me", its own broadcast channel. NQE is that vocabulary, kept small
on purpose. It was written to structure
[haskoin-node](https://github.com/jprupp/haskoin-node) and
[haskoin-store](https://github.com/jprupp/haskoin-store), where peers, the
header chain, the block importer and the cache are all NQE processes.

Use NQE when your program is naturally a set of long-lived components that
talk to each other: network services, nodes, pipelines, background workers. If
you only need to run a few things in parallel and collect their results, plain
`async` is simpler.

## Design principles

- **Ownership over sharing.** A process owns its state. Others hold a
  `Mailbox`, which can send but not receive, so they cannot interfere with it.
- **Build on STM, don't hide it.** Channels are STM queues and replies are STM
  actions. Anything NQE does can be combined with your own transactions.
- **The caller decides where replies go.** A request carries a callback
  (`Listen`) instead of a reply channel. `query` points it at a variable and
  waits, but you could point it at a queue, a counter or a log.
- **Back-pressure by default where it matters.** Bounded inboxes block fast
  producers instead of letting queues eat memory.
- **No silent failures.** Processes are linked to the thread that starts them,
  and supervisors always cancel their children when they stop.
- **Scoped lifetimes.** The `with` functions tie a process, supervisor or
  subscription to a block of code, so it cannot outlive it, even on an
  exception.
- **Plain `IO`.** Every action is an `IO` or `STM` action from the ordinary
  `base`, `stm` and `async` libraries. Signatures are short, and exceptions
  follow the rules of `Control.Exception`, with nothing in between. The cost is
  that code in a monad transformer stack has to `liftIO` its calls to NQE; see
  [Things to watch out for](#things-to-watch-out-for).
- **Not quite Erlang.** No distribution, no registry, no hot code reloading and
  no automatic restarts. Those features add a lot of machinery that most
  Haskell programs never use. Supervisors report deaths; your code decides
  whether a restart makes sense.

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
nightly snapshots. It is pure Haskell, with no C libraries to install, and
builds with any GHC that current Stackage snapshots support.

### Step by step with Stack

1. Install [Stack](https://docs.haskellstack.org/) (`curl -sSL
   https://get.haskellstack.org/ | sh`, or through your package manager).
2. Create a project and add the dependencies:

   ```sh
   stack new nqe-demo simple
   cd nqe-demo
   ```

   In `nqe-demo.cabal`, add `nqe` and `stm` to `build-depends` of the
   executable.
3. Paste the [quick start](#quick-start) program into `src/Main.hs`.
4. Build and run it:

   ```sh
   stack run
   ```

   It prints `Pong`.

### Step by step with Cabal

```sh
cabal update
mkdir nqe-demo && cd nqe-demo
cabal init --non-interactive --exe
```

Add `nqe` and `stm` to `build-depends` in `nqe-demo.cabal`, put the quick
start program in `app/Main.hs`, and run it with `cabal run`.

### Adding NQE to an existing project

With Cabal, list it in `build-depends`:

```cabal
build-depends:
    base
  , nqe
  , stm
```

With Stack and hpack, list it in `package.yaml`:

```yaml
dependencies:
  - nqe
  - stm
```

`stm` is there for `atomically`, which you need to run a `Listen` callback.


If your Stack resolver does not include NQE, or has an older version, add it
to `stack.yaml`:

```yaml
extra-deps:
  - nqe-0.7.0
```

## Quick start

A server that answers `Ping` with `Pong`, and a client that asks it once:

```haskell
import Control.Concurrent.STM (atomically)
import Control.Monad (forever)
import NQE

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

## Tutorial: a counter service

This walks through building a small service the NQE way. The service keeps a
count, other threads increment it and read it, and a supervisor makes sure the
program stops cleanly if anything goes wrong.

### 1. Describe the messages

A process is defined by the messages it understands. Requests that need an
answer carry a `Listen` callback for the reply:

```haskell
data CounterMsg
  = Increment Int              -- fire and forget
  | GetCount (Listen Int)      -- request with a reply
```

### 2. Write the process

The process owns its state. Here the state is passed along the loop, so there
is no shared variable at all:

```haskell
counter :: Inbox CounterMsg -> IO ()
counter inbox = go 0
  where
    go n =
      receive inbox >>= \case
        Increment k -> go (n + k)
        GetCount reply -> atomically (reply n) >> go n
```

### 3. Give it a friendly interface

Callers should not need to know about messages. Wrap them in functions that
take the `Mailbox`, the send-only end:

```haskell
increment :: Mailbox CounterMsg -> Int -> IO ()
increment mbox k = send (Increment k) mbox

getCount :: Mailbox CounterMsg -> IO Int
getCount = query GetCount
```

### 4. Start it and use it

```haskell
{-# LANGUAGE LambdaCase #-}

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (replicateM_)
import NQE

main :: IO ()
main = do
  (inbox, mbox) <- newMailbox
  withSupervisor IgnoreGraceful $ \sup -> do
    _ <- addChild sup (counter inbox)
    _ <- addChild sup (replicateM_ 1000 (increment mbox 1))
    _ <- addChild sup (replicateM_ 1000 (increment mbox 1))
    threadDelay 100000
    getCount mbox >>= print -- 2000
```

The strategy is the important decision. The two workers are expected to finish,
so a normal exit must not bring the group down; but if anything crashes,
including the counter, the rest cannot be trusted, so the whole group should
stop and the exception should reach `main`. That is exactly `IgnoreGraceful`.
With `KillAll`, the first worker to finish would stop the counter too, and
`getCount` would wait forever.

### 5. Where to go from here

- Make the inbox bounded with `newBoundedInbox` if producers could outrun the
  counter.
- Publish every change with a `Publisher` so that other components can react
  to it.
- Use `queryS 5 GetCount mbox` instead of `query` when the counter might be
  gone, so callers do not hang.

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

`withProcess` and `process` link the new thread to the caller with `link` from
the `async` package. An exception in the child is re-thrown in the parent as an
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

When the supervisor stops, it cancels all its children and waits for them. It
does that with asynchronous exceptions blocked, so cancelling the supervisor
twice cannot leave children behind.

`KillAll` and `IgnoreGraceful` re-throw the exception that stopped a child. If
the child died of an asynchronous exception, for example because some other
thread called `cancel` on it instead of `removeChild`, the supervisor throws it
wrapped in `AsyncChildException`. That keeps it an error: thrown unwrapped, an
`AsyncCancelled` would pass for a normal cancellation of the supervisor and
nobody would be told. `Notify` always gets the original exception.

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

With a bounded mailbox, a slow consumer slows down the producer. The sink runs
in `IO`; in a pipeline over another monad, use `transPipe liftIO`.

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
- Everything runs in `IO`. From a `ReaderT` or `LoggingT` stack, call NQE with
  `liftIO`, and run the stack again inside the `IO` action that you give to
  `withProcess`, `addChild` and the like. Versions before 0.7.0 did this for
  you; the [changelog](CHANGELOG.md) says how to migrate.
- Do not catch `SomeException` around NQE calls without letting asynchronous
  exceptions through. `cancel` and the linking of threads work by throwing
  them, and a handler that swallows them leaves threads that cannot be stopped.

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
