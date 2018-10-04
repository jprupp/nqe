{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent.Unique
import           Data.Function
import           Data.Hashable
import           UnliftIO

-- | 'STM' function that receives an event and does something with it.
type Listen a = a -> STM ()

-- | Mailbox view that only allows to send messages.
data Mailbox msg =
    forall mbox. (OutChan mbox) =>
                 Mailbox !(mbox msg)
                         !Unique

instance Exception TimeoutError

-- | Timed out request.
data TimeoutError
    = TimeoutError
    deriving (Show, Eq)

-- | Mailbox for a process allowing sending and receiving messages.
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

-- | Thread asynchronous handle and its mailbox.
data Process msg = Process
    { getProcessAsync   :: Async ()
    , getProcessMailbox :: Mailbox msg
    } deriving Eq

-- | Class for channels that can be used to build mailboxes.
class InChan mbox where
    -- | Are there pending messages?
    mailboxEmptySTM :: mbox msg -> STM Bool
    -- | Receive a message from mailbox in an 'STM' transaction.
    receiveSTM :: mbox msg -> STM msg
    -- | Re-enqueue a message in the mailbox such that it is the next element to
    -- be retrieved.
    requeueSTM :: msg -> mbox msg -> STM ()

class OutChan mbox where
    -- | Is this bounded mailbox full?
    mailboxFullSTM :: mbox msg -> STM Bool
    -- | Send a 'Dynamic' to the mailbox in an 'STM' transaction.
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

-- | Remove read capabilities from an 'Inbox' to get a write-only 'Mailbox'.
inboxToMailbox :: Inbox msg -> Mailbox msg
inboxToMailbox (Inbox m u) = Mailbox m u

-- | Wrap a bi-directional channel in an 'Inbox'.
wrapChannel ::
       (MonadIO m, InChan mbox, OutChan mbox) => mbox msg -> m (Inbox msg)
wrapChannel mbox = Inbox mbox <$> liftIO newUnique

-- | Create an unbounded 'Inbox'.
newInbox :: MonadIO m => m (Inbox msg)
newInbox = newTQueueIO >>= \c -> wrapChannel c

-- | Create a new 'Inbox' that can only store a maximum number of messages.
newBoundedInbox :: MonadIO m => Int -> m (Inbox msg)
newBoundedInbox i = newTBQueueIO i >>= \c -> wrapChannel c

-- | Send a message to a 'Mailbox'.
send :: (MonadIO m, OutChan mbox) => msg -> mbox msg -> m ()
send msg = atomically . sendSTM msg

-- | Receive a message from a 'Mailbox'. Will block until a message of the right
-- type appears. Any message of the wrong type will remain in the mailbox.
receive :: (InChan mbox, MonadIO m) => mbox msg -> m msg
receive mbox = receiveMatch mbox Just

-- | Send request to mailbox and wait for a response. Provide a function that
-- takes an 'Listen' action and produces a request. The remote process should
-- fulfill the action, and at this point this function will return the response.
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
queryS s f m = timeout s (query f m)

-- | Do a 'query' but timeout after 30 seconds. Return 'Nothing' if
-- timeout reached.
query30 ::
       (MonadUnliftIO m, OutChan mbox)
    => (Listen response -> request)
    -> mbox request
    -> m (Maybe response)
query30 = queryS 30

-- | Do a 'query', return the response or timeout after 30 seconds throwing a
-- 'TimeoutError'.
queryT :: (MonadUnliftIO m, OutChan mbox) => (Listen response -> request)
    -> mbox request -> m response
queryT request mbox =
    request `query30` mbox >>= maybe (throwIO TimeoutError) return

-- | Test all messages in a mailbox against the supplied function and return the
-- matching message. Will block until a match is found. Messages that do not
-- match remain in the mailbox.
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

-- | Like 'receiveMatch' but with a timeout set at @u@ seconds. Returns
-- 'Nothing' if timeout is reached.
receiveMatchS ::
       (MonadUnliftIO m, InChan mbox)
    => Int
    -> mbox msg
    -> (msg -> Maybe a)
    -> m (Maybe a)
receiveMatchS s mbox f = timeout (s * 1000 * 1000) $ receiveMatch mbox f

-- | Like 'receiveMatch' but with a timeout set at 30 seconds. Returns
-- 'Nothing' if timeout is reached.
receiveMatch30 ::
       (MonadUnliftIO m, InChan mbox)
    => mbox msg
    -> (msg -> Maybe a)
    -> m (Maybe a)
receiveMatch30 mbox f = timeout (30 * 1000 * 1000) $ receiveMatch mbox f

-- | Like 'receiveMatch30' but throw a 'TimeoutError' if timeout reached.
receiveMatchT ::
       (MonadUnliftIO m, InChan mbox) => mbox msg -> (msg -> Maybe a) -> m a
receiveMatchT mbox f =
    timeout (30 * 1000 * 1000) (receiveMatch mbox f) >>=
    maybe (throwIO TimeoutError) return

-- | Match a message in the mailbox as an atomic STM action.
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

-- | Check if the mailbox is empty.
mailboxEmpty :: (MonadIO m, InChan mbox) => mbox msg -> m Bool
mailboxEmpty = atomically . mailboxEmptySTM

-- | Put a message at the start of a mailbox, so that it is the next one read.
requeueListSTM :: InChan mbox => [msg] -> mbox msg -> STM ()
requeueListSTM xs mbox = mapM_ (`requeueSTM` mbox) xs

-- | Run a process in the background. Stop the background process once the associated
-- action returns. Background process thread is linked using 'link'.
withProcess ::
       MonadUnliftIO m => (Inbox msg -> m ()) -> (Process msg -> m a) -> m a
withProcess p f = do
    (i, m) <- newMailbox
    withAsync (p i) (\a -> link a >> f (Process a m))

-- | Run a process in the background and return the 'Process' handle. Background
-- process thread is linked using 'link'.
process :: MonadUnliftIO m => (Inbox msg -> m ()) -> m (Process msg)
process p = do
    (i, m) <- newMailbox
    a <- async $ p i
    link a
    return (Process a m)

newMailbox :: MonadUnliftIO m => m (Inbox msg, Mailbox msg)
newMailbox = do
    i <- newInbox
    let m = inboxToMailbox i
    return (i, m)
