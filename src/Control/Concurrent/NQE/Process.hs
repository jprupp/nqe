{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent.Unique
import           Control.Monad
import           Data.Dynamic
import           Data.Function
import           Data.Hashable
import           UnliftIO

-- | Wrapper for STM action to send a reply to a request.
type Reply a = a -> STM ()

-- | Mailbox view that only allows to send messages.
data Mailbox =
    forall mbox. (OutChan mbox) =>
                 Mailbox !mbox
                         !Unique

-- | Function for sorting dispatchers for different types of incoming message.
data Dispatch m =
    forall msg. (Typeable msg) => Dispatch { getDispatcher :: msg -> m () }

-- | Mailbox for a process allowing sending and receiving messages.
data Inbox =
    forall mbox. (OutChan mbox, InChan mbox) =>
                 Inbox !mbox
                       !Unique

instance Eq Mailbox where
    (==) = (==) `on` f
      where
        f (Mailbox _ u) = u

instance Eq Inbox where
    (==) = (==) `on` f
      where
        f (Inbox _ u) = u

-- | Thread asynchronous handle and its mailbox.
data Process = Process
    { getProcessAsync   :: Async ()
    , getProcessMailbox :: Mailbox
    } deriving (Typeable)

instance Eq Process where
    (==) = (==) `on` getProcessMailbox

-- | Class for channels that can be used to build mailboxes.
class (Eq mbox, Typeable mbox) => InChan mbox where
    -- | Are there pending messages?
    mailboxEmptySTM :: mbox -> STM Bool
    -- | Receive a 'Dynamic' from mailbox in an 'STM' transaction.
    receiveDynSTM :: mbox -> STM Dynamic
    -- | Re-enqueue a 'Dynamic' in the mailbox such that it is the next element
    -- to be retrieved by 'receiveDynSTM'.
    requeueDynSTM :: Dynamic -> mbox -> STM ()

class (Eq mbox, Typeable mbox) => OutChan mbox where
    -- | Is this bounded mailbox full?
    mailboxFullSTM :: mbox -> STM Bool
    -- | Send a 'Dynamic' to the mailbox in an 'STM' transaction.
    sendDynSTM :: Dynamic -> mbox -> STM ()

instance InChan (TQueue Dynamic) where
    mailboxEmptySTM = isEmptyTQueue
    receiveDynSTM = readTQueue
    requeueDynSTM msg = (`unGetTQueue` msg)

instance OutChan (TQueue Dynamic) where
    mailboxFullSTM _ = return False
    sendDynSTM msg = (`writeTQueue` msg)

instance InChan (TBQueue Dynamic) where
    mailboxEmptySTM = isEmptyTBQueue
    receiveDynSTM = readTBQueue
    requeueDynSTM msg = (`unGetTBQueue` msg)

instance OutChan (TBQueue Dynamic) where
    mailboxFullSTM = isFullTBQueue
    sendDynSTM msg = (`writeTBQueue` msg)

instance OutChan Mailbox where
    mailboxFullSTM (Mailbox mbox _) = mailboxFullSTM mbox
    sendDynSTM msg (Mailbox mbox _) = msg `sendDynSTM` mbox

instance InChan Inbox where
    mailboxEmptySTM (Inbox mbox _) = mailboxEmptySTM mbox
    receiveDynSTM (Inbox mbox _) = receiveDynSTM mbox
    requeueDynSTM msg (Inbox mbox _) = msg `requeueDynSTM` mbox

instance OutChan Inbox where
    mailboxFullSTM (Inbox mbox _) = mailboxFullSTM mbox
    sendDynSTM msg (Inbox mbox _) = msg `sendDynSTM` mbox

instance OutChan Process where
    mailboxFullSTM (Process _ mbox) = mailboxFullSTM mbox
    sendDynSTM msg (Process _ mbox) = msg `sendDynSTM` mbox

instance Hashable Process where
    hashWithSalt i (Process _ m) = hashWithSalt i m
    hash (Process _ m) = hash m

instance Hashable Mailbox where
    hashWithSalt i (Mailbox _ u) = hashWithSalt i u
    hash (Mailbox _ u) = hash u

-- | Remove read capabilities from an 'Inbox' to get a write-only 'Mailbox'.
inboxToMailbox :: Inbox -> Mailbox
inboxToMailbox (Inbox m u) = Mailbox m u

-- | Wrap a bi-directional channel in an 'Inbox'.
wrapChannel :: (MonadIO m, InChan mbox, OutChan mbox) => mbox -> m Inbox
wrapChannel mbox = Inbox mbox <$> liftIO newUnique

-- | Create an unbounded 'Inbox'.
newInbox :: MonadIO m => m Inbox
newInbox = newTQueueIO >>= \c -> wrapChannel (c :: TQueue Dynamic)

-- | Create a new 'Inbox' that can only store a maximum number of messages.
newBoundedInbox :: MonadIO m => Int -> m Inbox
newBoundedInbox i = newTBQueueIO i >>= \c -> wrapChannel (c :: TBQueue Dynamic)

-- | Send a message to a 'Mailbox'.
send :: (MonadIO m, Typeable msg, OutChan mbox) => msg -> mbox -> m ()
send msg = atomically . sendSTM msg

-- | Send a message to a 'Mailbox' in an 'STM' transaction.
sendSTM :: (Typeable msg, OutChan mbox) => msg -> mbox -> STM ()
sendSTM msg = sendDynSTM (toDyn msg)

-- | Receive a message from a 'Mailbox'. Will block until a message of the right
-- type appears. Any message of the wrong type will remain in the mailbox.
receive :: (Typeable msg, InChan mbox, MonadIO m) => mbox -> m msg
receive mbox = receiveMatch mbox Just

-- | Receive a message from a 'Mailbox' in an 'STM' transaction. Will block
-- until a message of the right type appears. Any message of the wrong type will
-- remain in the mailbox.
receiveSTM :: (Typeable msg, InChan mbox) => mbox -> STM msg
receiveSTM mbox = receiveMatchSTM mbox Just

receiveDyn :: (MonadIO m, InChan mbox) => mbox -> m Dynamic
receiveDyn = atomically . receiveDynSTM

-- | Dispatch incoming message according to its type.
-- | If message cannot be dispatched, discard or run default action if present.
dispatch ::
       (MonadIO m, InChan mbox)
    => Maybe (Dynamic -> m ()) -- ^ action if cannot dispatch
    -> mbox
    -> [Dispatch m]
    -> m ()
dispatch md mbox ds = join $ atomically (dispatchSTM md mbox ds)

-- | Dispatch incoming message according to its type as an STM function. If
-- message cannot be dispatched, discard or return default action if one is
-- provided.
dispatchSTM ::
       (Applicative m, InChan mbox)
    => Maybe (Dynamic -> m ())
    -> mbox
    -> [Dispatch m]
    -> STM (m ())
dispatchSTM md mbox ds = receiveDynSTM mbox >>= go ds
  where
    go [] msg = return $ maybe (pure ()) ($ msg) md
    go (Dispatch f:xs) msg =
        case fromDynamic msg of
            Just a  -> return (f a)
            Nothing -> go xs msg

-- | Send request to mailbox and wait for a response. Provide a function that
-- takes an 'Reply' action and produces a request. The remote process should
-- fulfill the action, and at this point this function will return the response.
query ::
       (MonadIO m, Typeable request, OutChan mbox)
    => (Reply response -> request)
    -> mbox
    -> m response
query f m = do
    r <- newEmptyTMVarIO
    f (putTMVar r) `send` m
    atomically $ takeTMVar r

-- | Do a 'query' but timeout after @u@ microseconds. Return 'Nothing' if
-- timeout reached.
queryU ::
       (MonadUnliftIO m, Typeable request, OutChan mbox)
    => Int
    -> (Reply response -> request)
    -> mbox
    -> m (Maybe response)
queryU u f m = timeout u (query f m)

-- | Do a 'query' but timeout after @s@ seconds. Return 'Nothing' if
-- timeout reached.
queryS ::
       (MonadUnliftIO m, Typeable request, OutChan mbox)
    => Int
    -> (Reply response -> request)
    -> mbox
    -> m (Maybe response)
queryS s f m = timeout s (query f m)

-- | Do a 'query' but timeout after 30 seconds. Return 'Nothing' if
-- timeout reached.
query30 ::
       (MonadUnliftIO m, Typeable request, OutChan mbox)
    => (Reply response -> request)
    -> mbox
    -> m (Maybe response)
query30 = queryS 30

-- | Test all messages in a mailbox against the supplied function and return the
-- matching message. Will block until a match is found. Messages that do not
-- match remain in the mailbox.
receiveMatch ::
       (MonadIO m, Typeable msg, InChan mbox) => mbox -> (msg -> Maybe a) -> m a
receiveMatch mbox = atomically . receiveMatchSTM mbox

-- | Like 'receiveMatch' but with a timeout set at @u@ microseconds. Returns
-- 'Nothing' if timeout is reached.
receiveMatchU ::
       (MonadUnliftIO m, Typeable msg, InChan mbox)
    => Int
    -> mbox
    -> (msg -> Maybe a)
    -> m (Maybe a)
receiveMatchU u mbox f = timeout u $ receiveMatch mbox f

-- | Like 'receiveMatch' but with a timeout set at @u@ seconds. Returns
-- 'Nothing' if timeout is reached.
receiveMatchS ::
       (MonadUnliftIO m, Typeable msg, InChan mbox)
    => Int
    -> mbox
    -> (msg -> Maybe a)
    -> m (Maybe a)
receiveMatchS s mbox f = timeout s $ receiveMatch mbox f

-- | Like 'receiveMatch' but with a timeout set at 30 seconds. Returns
-- 'Nothing' if timeout is reached.
receiveMatch30 ::
       (MonadUnliftIO m, Typeable msg, InChan mbox)
    => mbox
    -> (msg -> Maybe a)
    -> m (Maybe a)
receiveMatch30 mbox f = timeout (30 * 1000 * 1000) $ receiveMatch mbox f

-- | Match a message in the mailbox as an atomic STM action.
receiveMatchSTM ::
       (Typeable msg, InChan mbox) => mbox -> (msg -> Maybe a) -> STM a
receiveMatchSTM mbox f = go []
  where
    go acc =
        receiveDynSTM mbox >>= \msg ->
            case fromDynamic msg >>= f of
                Just x -> do
                    requeueListSTM acc mbox
                    return x
                Nothing -> go (msg : acc)

-- | Check if the mailbox is empty.
mailboxEmpty :: (MonadIO m, InChan mbox) => mbox -> m Bool
mailboxEmpty = atomically . mailboxEmptySTM

-- | Put a message at the start of a mailbox, so that it is the next one read.
requeueListSTM :: InChan mbox => [Dynamic] -> mbox -> STM ()
requeueListSTM xs mbox = mapM_ (`requeueDynSTM` mbox) xs

-- | Run a process in the background. Stop the background process once the associated
-- action returns. Background process thread is linked using 'link'.
withProcess :: MonadUnliftIO m => (Inbox -> m ()) -> (Process -> m a) -> m a
withProcess p f = do
    (i, m) <- newMailbox
    withAsync (p i) (\a -> link a >> f (Process a m))

-- | Run a process in the background and return the 'Process' handle. Background
-- process thread is linked using 'link'.
process :: MonadUnliftIO m => (Inbox -> m ()) -> m Process
process p = do
    (i, m) <- newMailbox
    a <- async $ p i
    link a
    return (Process a m)

newMailbox :: MonadUnliftIO m => m (Inbox, Mailbox)
newMailbox = do
    i <- newInbox
    let m = inboxToMailbox i
    return (i, m)
