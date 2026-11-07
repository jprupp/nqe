{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-|
Module      : Control.Concurrent.NQE.Process
Copyright   : Haskoin Developers
License     : MIT
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

This is the core of the NQE library. It is composed of code to deal with
processes and mailboxes. Processes represent concurrent threads that receive
messages via a mailbox, also referred to as a channel. NQE is inspired by
Erlang/OTP and it stands for “Not Quite Erlang”. A process is analogous to an
actor in Scala, or an object in the original (Alan Kay) sense of the word. To
implement synchronous communication NQE makes use of 'STM' actions embedded in
asynchronous messages.

= Why processes and mailboxes

Shared mutable state is the usual source of trouble in concurrent programs:
two threads change the same thing, and the result depends on timing. The
Erlang answer, which NQE borrows, is to give each piece of state an owner. A
process owns its state outright, and other threads can only ask it to do
things by sending messages. The process handles one message at a time, so its
state is never seen half-changed and needs no locks.

Haskell already has excellent building blocks for this: lightweight threads,
'STM' and the @async@ package. NQE does not replace them. It is a thin layer
that names the patterns people end up writing by hand on top of them, so that
programs built from many cooperating threads read the same way everywhere.

= Design choices

* __Everything is STM.__ Channels are 'TQueue' or 'TBQueue', and replies are
  'STM' actions. This means a send, a receive and a reply can be combined with
  any other transaction, and selective receive ('receiveMatch') can be done
  atomically.

* __Replies are callbacks, not return channels.__ A request carries a 'Listen'
  action that the receiver runs. The sender decides where the reply goes: a
  'TMVar' for 'query', a queue for a stream of replies, or nowhere at all.
  The receiver does not need to know.

* __Sending and receiving are separate capabilities.__ An 'Inbox' can receive;
  a 'Mailbox' can only send. Handing out a 'Mailbox' lets other threads talk to
  a process without being able to steal its messages.

* __Bounded channels give back-pressure.__ A fast producer writing to a
  bounded inbox blocks until the consumer catches up, instead of filling
  memory.

* __Failures are loud.__ 'withProcess' and 'process' link the new thread to its
  parent, so an exception in a process is re-thrown in the thread that started
  it rather than disappearing.

* __Not quite Erlang.__ There is no distribution, no process registry, no
  hot code loading and no automatic restarts. Those features cost a lot of
  complexity and most Haskell programs that want actors do not need them.

= Overview

* An 'Inbox' is the receiving end of a channel. Only the process that owns it
  should read from it.
* A 'Mailbox' is the sending end of the same channel. It can be shared freely
  with any thread that needs to talk to the process.
* A 'Process' bundles the 'Async' handle of a running thread together with its
  'Mailbox'.

Channels can be unbounded ('newInbox') or bounded ('newBoundedInbox'). Sending
to a full bounded channel blocks until there is space.

= Synchronous requests

Request/response communication is done by embedding a 'Listen' action in a
message. The receiving process runs the action to deliver its reply. The
'query' family of functions takes care of creating the reply variable and
waiting on it:

@
data Ping = Ping ('Listen' Pong)
data Pong = Pong

pongServer :: 'Inbox' Ping -> IO ()
pongServer inbox = forever $ do
    Ping reply <- 'receive' inbox
    atomically (reply Pong)

main :: IO ()
main = 'withProcess' pongServer $ \\p -> do
    Pong <- 'query' Ping p
    return ()
@
-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent.Unique
import           Data.Function
import           Data.Hashable
import           Numeric.Natural
import           UnliftIO

-- | 'STM' function that receives an event and does something with it.
--
-- This is typically used as a callback embedded in a message so that the
-- receiver can reply to the sender, or by a 'Control.Concurrent.NQE.Publisher'
-- to forward events to subscribers. Because it runs in 'STM' it must not block
-- for long, and should normally just write to a 'TMVar', 'TQueue' or similar.
--
-- Using an 'STM' callback rather than a reply channel keeps the receiver
-- ignorant of how the sender wants its answer, and lets the reply be part of the
-- same transaction as whatever else the receiver does.
type Listen a = a -> STM ()

-- | Channel that only allows messages to be sent to it.
--
-- A 'Mailbox' hides the underlying channel implementation, so that any type
-- with an 'OutChan' instance can be used. Each mailbox carries a 'Unique'
-- identifier, which is used for its 'Eq' and 'Hashable' instances. Two
-- mailboxes are equal if and only if they point to the same channel.
--
-- Obtain one from an 'Inbox' using 'inboxToMailbox', or create a pair with
-- 'newMailbox'.
--
-- The point of a separate send-only type is the principle of least authority:
-- code that only needs to talk to a process should not be able to read its
-- messages. The existential type also hides which kind of channel is behind it,
-- so a bounded and an unbounded process look the same to their clients.
data Mailbox msg =
    forall mbox. (OutChan mbox) =>
                 Mailbox !(mbox msg)
                         !Unique

-- | Channel that allows to send or receive messages.
--
-- An 'Inbox' is the receiving end of a channel and should be owned by a single
-- process. Like 'Mailbox', it carries a 'Unique' identifier used for equality.
-- Create one with 'newInbox', 'newBoundedInbox' or 'wrapChannel'.
--
-- An inbox is the private end of a process. Keep it inside the process and
-- share the 'Mailbox' made from it with 'inboxToMailbox'.
data Inbox msg =
    forall mbox. (OutChan mbox, InChan mbox) =>
                 Inbox !(mbox msg)
                       !Unique

instance Eq (Mailbox msg) where
    (==) = (==) `on` f
      where
        f (Mailbox _ u) = u

instance Eq (Inbox msg) where
    (==) = (==) `on` f
      where
        f (Inbox _ u) = u

-- | 'Async' handle and 'Mailbox' for a process.
--
-- A 'Process' is an instance of 'OutChan', so messages can be sent to it
-- directly using 'send' or 'query'. Use 'getProcessAsync' to wait for the
-- process or cancel it.
data Process msg = Process
    { getProcessAsync   :: Async ()
      -- ^ handle of the thread running the process
    , getProcessMailbox :: Mailbox msg
      -- ^ mailbox used to send messages to the process
    } deriving Eq

-- | Class for implementation of an 'Inbox'.
--
-- Instances are provided for 'TQueue', 'TBQueue' and 'Inbox'.
--
-- The classes exist so that the same functions work on raw STM queues, on
-- 'Inbox' and 'Mailbox', and on 'Process' handles. They are the extension point
-- for other channel types.
class InChan mbox where
    -- | Are there messages queued?
    mailboxEmptySTM :: mbox msg -> STM Bool
    -- | Receive a message.
    receiveSTM :: mbox msg -> STM msg
    -- | Put a message in the mailbox such that it is received next.
    requeueSTM :: msg -> mbox msg -> STM ()

-- | Class for implementation of a 'Mailbox'.
--
-- Instances are provided for 'TQueue', 'TBQueue', 'Mailbox', 'Inbox' and
-- 'Process'.
class OutChan mbox where
    -- | Is this bounded channel full? Always 'False' for unbounded channels.
    mailboxFullSTM :: mbox msg -> STM Bool
    -- | Send a message to this channel. Retries (blocks) if a bounded channel
    -- is full.
    sendSTM :: msg -> mbox msg -> STM ()

instance InChan TQueue where
    mailboxEmptySTM = isEmptyTQueue
    receiveSTM = readTQueue
    requeueSTM msg = (`unGetTQueue` msg)

instance OutChan TQueue where
    mailboxFullSTM _ = return False
    sendSTM msg = (`writeTQueue` msg)

instance InChan TBQueue where
    mailboxEmptySTM = isEmptyTBQueue
    receiveSTM = readTBQueue
    requeueSTM msg = (`unGetTBQueue` msg)

instance OutChan TBQueue where
    mailboxFullSTM = isFullTBQueue
    sendSTM msg = (`writeTBQueue` msg)

instance OutChan Mailbox where
    mailboxFullSTM (Mailbox mbox _) = mailboxFullSTM mbox
    sendSTM msg (Mailbox mbox _) = msg `sendSTM` mbox

instance InChan Inbox where
    mailboxEmptySTM (Inbox mbox _) = mailboxEmptySTM mbox
    receiveSTM (Inbox mbox _) = receiveSTM mbox
    requeueSTM msg (Inbox mbox _) = msg `requeueSTM` mbox

instance OutChan Inbox where
    mailboxFullSTM (Inbox mbox _) = mailboxFullSTM mbox
    sendSTM msg (Inbox mbox _) = msg `sendSTM` mbox

instance OutChan Process where
    mailboxFullSTM (Process _ mbox) = mailboxFullSTM mbox
    sendSTM msg (Process _ mbox) = msg `sendSTM` mbox

instance Hashable (Process msg) where
    hashWithSalt i (Process _ m) = hashWithSalt i m
    hash (Process _ m) = hash m

instance Hashable (Mailbox msg) where
    hashWithSalt i (Mailbox _ u) = hashWithSalt i u
    hash (Mailbox _ u) = hash u

-- | Get a send-only 'Mailbox' for an 'Inbox'.
inboxToMailbox :: Inbox msg -> Mailbox msg
inboxToMailbox (Inbox m u) = Mailbox m u

-- | Wrap a channel in an 'Inbox'. A fresh 'Unique' identifier is generated, so
-- wrapping the same channel twice yields two 'Inbox' values that are not equal.
wrapChannel ::
       (MonadIO m, InChan mbox, OutChan mbox) => mbox msg -> m (Inbox msg)
wrapChannel mbox = Inbox mbox <$> liftIO newUnique

-- | Create an unbounded 'Inbox' backed by a 'TQueue'.
newInbox :: MonadIO m => m (Inbox msg)
newInbox = newTQueueIO >>= \c -> wrapChannel c

-- | Create an 'Inbox' backed by a 'TBQueue' with an upper bound on the number
-- of queued messages. Senders block while the inbox is full.
--
-- Prefer a bounded inbox whenever the producer can outpace the consumer, such
-- as a process fed by the network. Blocking the producer is almost always better
-- than letting the queue, and the program's memory, grow without limit.
newBoundedInbox :: MonadIO m => Natural -> m (Inbox msg)
newBoundedInbox i = newTBQueueIO (fromIntegral i) >>= \c -> wrapChannel c

-- | Send a message to a channel. Blocks if the channel is bounded and full.
send :: (MonadIO m, OutChan mbox) => msg -> mbox msg -> m ()
send msg = atomically . sendSTM msg

-- | Receive the next message from a channel. Blocks until a message is
-- available.
receive :: (InChan mbox, MonadIO m) => mbox msg -> m msg
receive mbox = receiveMatch mbox Just

-- | Send request to channel and wait for a response. The @request@ 'STM' action
-- will be created by this function.
--
-- The first argument is usually a data constructor that takes a 'Listen'
-- callback as its last field. This function creates an empty 'TMVar', builds
-- the request with a callback that fills it, sends the request, and blocks until
-- the receiver runs the callback.
--
-- If the receiver never answers, this function blocks forever. See 'queryU' and
-- 'queryS' for versions with a timeout.
--
-- This is the NQE equivalent of a function call across threads. It is also the
-- main way to deadlock an NQE program: a process that queries another process
-- that is, directly or indirectly, querying it back will wait forever. Keep
-- requests flowing in one direction, or use 'queryS' with a timeout.
query ::
       (MonadIO m, OutChan mbox)
    => (Listen response -> request)
    -> mbox request
    -> m response
query f m = do
    r <- newEmptyTMVarIO
    f (putTMVar r) `send` m
    atomically $ takeTMVar r

-- | Do a 'query' but timeout after @u@ microseconds. Return 'Nothing' if
-- timeout reached.
queryU ::
       (MonadUnliftIO m, OutChan mbox)
    => Int
    -> (Listen response -> request)
    -> mbox request
    -> m (Maybe response)
queryU u f m = timeout u (query f m)

-- | Do a 'query' but timeout after @s@ seconds. Return 'Nothing' if
-- timeout reached.
queryS ::
       (MonadUnliftIO m, OutChan mbox)
    => Int
    -> (Listen response -> request)
    -> mbox request
    -> m (Maybe response)
queryS s f m = timeout (s * 1000 * 1000) (query f m)

-- | Test all messages in a channel against the supplied function and return the
-- first matching message. Will block until a match is found. Messages that do
-- not match remain in the channel.
--
-- Selective receive lets a process wait for one particular reply while leaving
-- other messages for later, as Erlang's @receive@ does. Use it sparingly: every
-- message that does not match is examined on each call, so a long queue of
-- unmatched messages makes it slow.
receiveMatch :: (MonadIO m, InChan mbox) => mbox msg -> (msg -> Maybe a) -> m a
receiveMatch mbox = atomically . receiveMatchSTM mbox

-- | Like 'receiveMatch' but with a timeout set at @u@ microseconds. Returns
-- 'Nothing' if timeout is reached.
receiveMatchU ::
       (MonadUnliftIO m, InChan mbox)
    => Int
    -> mbox msg
    -> (msg -> Maybe a)
    -> m (Maybe a)
receiveMatchU u mbox f = timeout u $ receiveMatch mbox f

-- | Like 'receiveMatch' but with a timeout set at @s@ seconds. Returns
-- 'Nothing' if timeout is reached.
receiveMatchS ::
       (MonadUnliftIO m, InChan mbox)
    => Int
    -> mbox msg
    -> (msg -> Maybe a)
    -> m (Maybe a)
receiveMatchS s mbox f = timeout (s * 1000 * 1000) $ receiveMatch mbox f

-- | Match a message in the channel as an atomic 'STM' action. Messages that do
-- not match are put back in the channel in their original order. Retries if no
-- message matches.
receiveMatchSTM :: InChan mbox => mbox msg -> (msg -> Maybe a) -> STM a
receiveMatchSTM mbox f = go []
  where
    go acc =
        receiveSTM mbox >>= \msg ->
            case f msg of
                Just x -> do
                    requeueListSTM acc mbox
                    return x
                Nothing -> go (msg : acc)

-- | Check if the channel is empty. The result may be stale as soon as it is
-- returned if other threads are writing to the channel.
mailboxEmpty :: (MonadIO m, InChan mbox) => mbox msg -> m Bool
mailboxEmpty = atomically . mailboxEmptySTM

-- | Put a list of messages at the start of a channel, so that the last element
-- of the list is the next message to be received.
requeueListSTM :: InChan mbox => [msg] -> mbox msg -> STM ()
requeueListSTM xs mbox = mapM_ (`requeueSTM` mbox) xs

-- | Run a process in the background and pass it to a function. Stop the
-- background process once the function returns. Background process exceptions
-- are re-thrown in the current thread.
--
-- The process receives the 'Inbox' of a newly-created unbounded channel. The
-- function receives the corresponding 'Process' handle. The background thread is
-- linked to the current one, so if it throws, the exception is re-thrown here
-- wrapped in 'ExceptionInLinkedThread'.
--
-- This is the function to reach for first. Tying the lifetime of the process to
-- a scope means it cannot outlive the code that uses it, and linking means it
-- cannot fail silently.
withProcess ::
       MonadUnliftIO m => (Inbox msg -> m ()) -> (Process msg -> m a) -> m a
withProcess p f = do
    (i, m) <- newMailbox
    withAsync (p i) (\a -> link a >> f (Process a m))

-- | Run a process in the background and return the 'Process' handle. Background
-- process exceptions are re-thrown in the current thread.
--
-- Unlike 'withProcess', the process is not stopped automatically. Cancel it with
-- 'cancel' on 'getProcessAsync' when it is no longer needed. Prefer
-- 'withProcess' where possible, since it is exception-safe.
process :: MonadUnliftIO m => (Inbox msg -> m ()) -> m (Process msg)
process p = do
    (i, m) <- newMailbox
    a <- async $ p i
    link a
    return (Process a m)

-- | Create an unbounded inbox and corresponding mailbox.
newMailbox :: MonadUnliftIO m => m (Inbox msg, Mailbox msg)
newMailbox = do
    i <- newInbox
    let m = inboxToMailbox i
    return (i, m)
