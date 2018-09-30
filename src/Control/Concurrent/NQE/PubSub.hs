{-# LANGUAGE FlexibleContexts #-}
module Control.Concurrent.NQE.PubSub
    ( Publisher
    , PubMsg(..)
    , publisher
    , subscribe
    , unsubscribe
    , withPubSub
    ) where

import           Control.Concurrent.NQE.Process
import           Control.Monad.Reader
import           Data.List
import           UnliftIO

-- | Subscribe or unsubscribe from an event publisher.
data PubMsg event
    = Subscribe (Inbox event)
    | Unsubscribe (Inbox event)
    | Event event

-- | Wrapper for a 'Mailbox' that can receive 'ControlMsg'.
type Publisher msg = Inbox (PubMsg msg)

-- | Subscribe an 'Inbox' to events from a 'Publisher'.
withPubSub ::
       MonadUnliftIO m
    => Maybe Int -- ^ limit of events to queue
    -> Publisher event
    -> (Inbox event -> m a) -- ^ unsubscribe when this action ends
    -> m a
withPubSub bound pub = bracket acquire (unsubscribe pub)
  where
    acquire = do
        i <-
            case bound of
                Nothing -> newInbox =<< newTQueueIO
                Just n  -> newInbox =<< newTBQueueIO n
        subscribe pub i
        return i

-- | Subscribe an 'Inbox' to a 'Publisher' generating events.
subscribe :: MonadIO m => Publisher event -> Inbox event -> m ()
subscribe pub sub = Subscribe sub `send` pub

-- | Unsubscribe an 'Inbox' from a 'Publisher' events.
unsubscribe :: MonadIO m => Publisher event -> Inbox event -> m ()
unsubscribe pub sub = Unsubscribe sub `send` pub

-- | Start a publisher that will receive events from an 'STM' action, and
-- subscription requests from a 'Publisher' mailbox. Events will be forwarded
-- atomically to all subscribers. Full mailboxes will not receive events.
publisher :: MonadIO m => Publisher event -> m ()
publisher pub = do
    box <- newTVarIO []
    runReaderT go box
  where
    go = forever $ receive pub >>= process

process ::
       (MonadIO m, MonadReader (TVar [Inbox event]) m)
    => PubMsg event
    -> m ()
process (Subscribe sub) = do
    box <- ask
    atomically (modifyTVar box (`union` [sub]))

process (Unsubscribe sub) = do
    box <- ask
    atomically (modifyTVar box (delete sub))

process (Event event) = do
    box <- ask
    atomically $ do
        subs <- readTVar box
        forM_ subs $ \sub -> do
            full <- mailboxFullSTM sub
            unless full $ event `sendSTM` sub
