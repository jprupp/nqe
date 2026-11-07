# NQE: Not Quite Erlang

NQE is a small Haskell library for concurrency in the style of Erlang/OTP. It
gives you lightweight processes that talk to each other through mailboxes,
supervisors that watch over them, and publishers that broadcast messages to
subscribers. Everything is built on top of [STM](https://hackage.haskell.org/package/stm)
and [unliftio](https://hackage.haskell.org/package/unliftio), so it works in
`IO` as well as in any monad that implements `MonadUnliftIO`.

## Installation

Add `nqe` to the dependencies of your package:

```yaml
dependencies:
  - nqe
```

## Concepts

| Type             | What it is                                                             |
|------------------|------------------------------------------------------------------------|
| `Inbox msg`      | Receiving end of a channel. Owned by one process.                      |
| `Mailbox msg`    | Sending end of a channel. Can be shared with any thread.               |
| `Process msg`    | A running thread (`Async ()`) together with its `Mailbox`.             |
| `Listen a`       | An `a -> STM ()` callback, used for replies and subscriptions.         |
| `Supervisor`     | A process that starts, monitors and stops child threads.               |
| `Publisher msg`  | A process that forwards every message it gets to its subscribers.      |

### Processes and queries

A process is a function that takes an `Inbox`. Start it with `withProcess`
(scoped, exception-safe) or `process` (unscoped). Send messages with `send`.
For request/response, put a `Listen` callback in your message and use `query`:

```haskell
import NQE
import Control.Monad (forever)
import UnliftIO

newtype Ping = Ping (Listen Pong)
data Pong = Pong deriving Show

pongServer :: Inbox Ping -> IO ()
pongServer inbox = forever $ do
    Ping reply <- receive inbox
    atomically (reply Pong)

main :: IO ()
main = withProcess pongServer $ \p -> do
    pong <- query Ping p
    print pong
```

`queryS` and `queryU` do the same but give up after a number of seconds or
microseconds. `receiveMatch` picks the first message in the inbox that matches
a function, leaving the rest in place.

Bounded inboxes are created with `newBoundedInbox`. Sending to a full bounded
inbox blocks, which gives you back-pressure for free.

### Supervisors

A supervisor runs child actions of type `IO ()` and reacts when they stop,
according to a `Strategy`:

- `KillAll`: if any child stops, stop every child and the supervisor, re-throwing
  the exception if there was one.
- `IgnoreGraceful`: ignore children that return normally; on an exception, stop
  everything and re-throw.
- `IgnoreAll`: ignore children that stop for any reason.
- `Notify listen`: call `listen` with the child and its exception (if any).

```haskell
withSupervisor KillAll $ \sup -> do
    _ <- addChild sup worker1
    _ <- addChild sup worker2
    mainLoop
```

When the supervisor stops, all of its children are cancelled.

### Publishers

A publisher forwards each published message to all of its subscribers.
`withSubscription` creates an inbox, subscribes it, and unsubscribes it when
done:

```haskell
withPublisher $ \pub ->
    withSubscription pub $ \inbox -> do
        publish "hello" pub
        receive inbox >>= putStrLn
```

If you use `subscribe` directly, remember to `unsubscribe` later, or the
publisher will keep a reference to your callback forever.

### Conduit integration

`conduitMailbox` is a conduit sink that sends every value it receives to a
mailbox:

```haskell
runConduit $ sourceHandle stdin .| conduitMailbox mailbox
```

## Modules

- `NQE` re-exports everything.
- `Control.Concurrent.NQE.Process`
- `Control.Concurrent.NQE.Supervisor`
- `Control.Concurrent.NQE.Publisher`
- `Control.Concurrent.NQE.Conduit`

Full API documentation is in the Haddock comments, and on
[Hackage](https://hackage.haskell.org/package/nqe).

## Building and testing

```sh
stack build
stack test
```

## License

MIT. See [LICENSE](LICENSE).
