{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-|
Module      : Control.Concurrent.NQE.Process
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

This is the core of the NQE library. It is composed of code to deal with
processes and mailboxes. Processes represent concurrent threads that receive
messages via a mailbox, also referred to as a channel. NQE is inspired by
Erlang/OTP and it stands for “Not Quite Erlang”. A process is analogous to an
actor in Scala, or an object in the original (Alan Kay) sense of the word. To
implement synchronous communication NQE makes use of 'STM' actions embedded in
asynchronous messages.
-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent.Unique
import           Data.Function
import           Data.Hashable
import           UnliftIO

-- | 'STM' function that receives an event and does something with it.
type Listen a = a -> STM ()

-- | Channel that only allows messages to be sent to it.
data Mailbox msg =
    forall mbox. (OutChan mbox) =>
                 Mailbox !(mbox msg)
                         !Unique

-- | Channel that allows to send or receive messages.
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
data Process msg = Process
    { getProcessAsync   :: Async ()
    , getProcessMailbox :: Mailbox msg
    } deriving Eq

-- | Class for implementation of an 'Inbox'.
class InChan mbox where
    -- | Are there messages queued?
    mailboxEmptySTM :: mbox msg -> STM Bool
    -- | Receive a message.
    receiveSTM :: mbox msg -> STM msg
    -- | Put a message in the mailbox such that it is received next.
    requeueSTM :: msg -> mbox msg -> STM ()

-- | Class for implementation of a 'Mailbox'.
class OutChan mbox where
    -- | Is this bounded channel full? Always 'False' for unbounded channels.
    mailboxFullSTM :: mbox msg -> STM Bool
    -- | Send a message to this channel.
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

-- | Wrap a channel in an 'Inbox'
wrapChannel ::
       (MonadIO m, InChan mbox, OutChan mbox) => mbox msg -> m (Inbox msg)
wrapChannel mbox = Inbox mbox <$> liftIO newUnique

-- | Create an unbounded 'Inbox'.
newInbox :: MonadIO m => m (Inbox msg)
newInbox = newTQueueIO >>= \c -> wrapChannel c

-- | 'Inbox' with upper bound on number of allowed queued messages.
newBoundedInbox :: MonadIO m => Int -> m (Inbox msg)
newBoundedInbox i = newTBQueueIO i >>= \c -> wrapChannel c

-- | Send a message to a channel.
send :: (MonadIO m, OutChan mbox) => msg -> mbox msg -> m ()
send msg = atomically . sendSTM msg

-- | Receive a message from a channel.
receive :: (InChan mbox, MonadIO m) => mbox msg -> m msg
receive mbox = receiveMatch mbox Just

-- | Send request to channel and wait for a response. The @request@ 'STM' action
-- will be created by this function.
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

-- | Match a message in the channel as an atomic 'STM' action.
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

-- | Check if the channel is empty.
mailboxEmpty :: (MonadIO m, InChan mbox) => mbox msg -> m Bool
mailboxEmpty = atomically . mailboxEmptySTM

-- | Put a list of messages at the start of a channel, so that the last element
-- of the list is the next message to be received.
requeueListSTM :: InChan mbox => [msg] -> mbox msg -> STM ()
requeueListSTM xs mbox = mapM_ (`requeueSTM` mbox) xs

-- | Run a process in the background and pass it to a function. Stop the
-- background process once the function returns. Background process exceptions
-- are rethrown in the current thread.
withProcess ::
       MonadUnliftIO m => (Inbox msg -> m ()) -> (Process msg -> m a) -> m a
withProcess p f = do
    (i, m) <- newMailbox
    withAsync (p i) (\a -> link a >> f (Process a m))

-- | Run a process in the background and return the 'Process' handle. Background
-- process exceptions are rethrown in the current thread.
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
