{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
module Control.Concurrent.NQE.Process
    ( Mailbox(..)
    , Inbox
    , Reply
    , Listen
    , newInbox
    , send
    , receive
    , query
    , receiveMatch
    , receiveMatchSTM
    , mailboxEmpty
    ) where

import           Control.Concurrent.Unique
import           Data.Hashable
import           UnliftIO

-- | STM action to reply to a synchronous request.
type Reply a = a -> STM ()

-- | STM action for an event listener.
type Listen a = a -> STM ()

-- | Mailboxes are used to communicate with processes (actors). A process will
-- usually listen in a loop for events entering its mailbox. A process is its
-- mailbox, so it may be named as the process that it communicates with.
--
-- >>> :m + Control.Monad NQE UnliftIO
-- >>> registry <- newTQueueIO :: IO (TQueue String)
-- >>> let run = receive registry >>= putStrLn . ("Registered: " ++)
-- >>> withAsync run $ \a -> "Bruce Wayne" `send` registry >> wait a
-- Registered: Bruce Wayne
class Eq (mbox msg) => Mailbox mbox msg where
    -- | STM action that responds true if the mailbox is empty. Useful to avoid
    -- blocking on an empty mailbox.
    mailboxEmptySTM :: mbox msg -> STM Bool
    -- | STM action that responds true if the mailbox is full and would block if
    -- a new message is received.
    mailboxFullSTM :: mbox msg -> STM Bool
    -- | STM action to send a message to a mailbox. This is usually called from
    -- a process that wishes to communicate with actor that owns the mailbox.
    sendSTM :: msg -> mbox msg -> STM ()
    -- | STM action to receive a message from a mailbox. This should be called
    -- from the process that owns the mailbox.
    receiveSTM :: mbox msg -> STM msg
    -- | Put a message back in the mailbox so that it is the next one to be
    -- received. Used for pattern matching.
    requeueSTM :: msg -> mbox msg -> STM ()

instance Mailbox TQueue msg where
    mailboxEmptySTM = isEmptyTQueue
    mailboxFullSTM = const $ return False
    sendSTM msg = (`writeTQueue` msg)
    receiveSTM = readTQueue
    requeueSTM msg = (`unGetTQueue` msg)

instance Mailbox TBQueue msg where
    mailboxEmptySTM = isEmptyTBQueue
    mailboxFullSTM = isFullTBQueue
    sendSTM msg = (`writeTBQueue` msg)
    receiveSTM = readTBQueue
    requeueSTM msg = (`unGetTBQueue` msg)

-- | Wrapped 'Mailbox' hiding its implementation.
data Inbox msg = forall mbox. (Mailbox mbox msg) => Inbox !(mbox msg) !Unique

-- | Create a new 'Inbox' with a 'Unique' identifier inside. If you run this
-- function more than once with the same 'Mailbox', its results will be
-- different from the 'Eq' or 'Hashable' point of view.
newInbox :: (MonadIO m, Mailbox mbox msg) => mbox msg -> m (Inbox msg)
newInbox mbox = Inbox mbox <$> liftIO newUnique

instance Eq (Inbox msg) where
    Inbox _ u1 == Inbox _ u2 = u1 == u2

instance Hashable (Inbox msg) where
    hashWithSalt i (Inbox _ u) = hashWithSalt i u
    hash (Inbox _ u) = hash u

instance Mailbox Inbox msg where
    mailboxEmptySTM (Inbox mbox _) = mailboxEmptySTM mbox
    mailboxFullSTM (Inbox mbox _) = mailboxFullSTM mbox
    sendSTM msg (Inbox mbox _) = msg `sendSTM` mbox
    receiveSTM (Inbox mbox _) = receiveSTM mbox
    requeueSTM msg (Inbox mbox _) = msg `requeueSTM` mbox

-- | Send a message to a mailbox.
send :: (MonadIO m, Mailbox mbox msg) => msg -> mbox msg -> m ()
send msg = atomically . sendSTM msg

-- | Receive a message from the mailbox. This function should be called only by
-- the process that owns the malibox.
receive ::
       (MonadIO m, Mailbox mbox msg)
    => mbox msg
    -> m msg
receive mbox = receiveMatch mbox Just

-- | Use a partially-applied message type that takes a `Reply a` as its last
-- argument. This function will create the STM action for the response, send the
-- message to a process and await for the STM action to be fulfilled before
-- responding response. It implements synchronous communication with a process.
--
-- Example:
--
-- >>> :m + NQE UnliftIO
-- >>> data Message = Square Integer (Reply Integer)
-- >>> doubler <- newTQueueIO :: IO (TQueue Message)
-- >>> let proc = receive doubler >>= \(Square i r) -> atomically $ r (i * i)
-- >>> withAsync proc $ \_ -> Square 2 `query` doubler
-- 4
--
-- In this example the @Square@ constructor takes a 'Reply' action as its last
-- argument. It is passed partially-applied to @query@, which adds a new 'Reply'
-- action before sending it to the @doubler@ and then waiting for it. The
-- doubler process will run the @Reply@ action n STM with the reply as its
-- argument. In this case @i * i@.
query ::
       (MonadIO m, Mailbox mbox msg)
    => (Reply a -> msg)
    -> mbox msg
    -> m a
query f mbox = do
    box <- atomically newEmptyTMVar
    f (putTMVar box) `send` mbox
    atomically (takeTMVar box)

-- | Test all the messages in a mailbox against the supplied function and return
-- the output of the function only when it is 'Just'. Will block until a message
-- matches. All messages that did not match are left in the mailbox. Only call
-- from process that owns mailbox.
receiveMatch ::
       (MonadIO m, Mailbox mbox msg) => mbox msg -> (msg -> Maybe a) -> m a
receiveMatch mbox = atomically . receiveMatchSTM mbox

-- | Match a message in the mailbox as an atomic STM action.
receiveMatchSTM ::
       (Mailbox mbox msg)
    => mbox msg
    -> (msg -> Maybe a)
    -> STM a
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
mailboxEmpty :: (MonadIO m, Mailbox mbox msg) => mbox msg -> m Bool
mailboxEmpty = atomically . mailboxEmptySTM

-- | Put a message at the start of a mailbox, so that it is the next one read.
requeueListSTM :: (Mailbox mbox msg) => [msg] -> mbox msg -> STM ()
requeueListSTM xs mbox = mapM_ (`requeueSTM` mbox) xs
