{-# LANGUAGE FlexibleContexts #-}
module Control.Concurrent.NQE.PubSub
    ( Publisher
    , publisher
    , subscribe
    , unsubscribe
    , withPubSub
    ) where

import           Control.Applicative
import           Control.Concurrent.NQE.Process
import           Control.Monad.Reader
import           Data.List
import           UnliftIO

-- | Subscribe or unsubscribe from an event publisher.
data ControlMsg event
    = Subscribe (Inbox event)
    | Unsubscribe (Inbox event)

-- | Wrapper for a 'Mailbox' that can receive 'ControlMsg'.
type Publisher msg = Inbox (ControlMsg msg)

-- | Subscribe an 'Inbox' to events from a 'Publisher'. Unsubscribe when action
-- finishes. Pass a mailbox constructor.
withPubSub ::
       (MonadUnliftIO m, Mailbox mbox event)
    => Publisher event
    -> m (mbox event)         -- ^ mailbox creator for this subscription
    -> (Inbox event -> m a)   -- ^ unsubscribe when this action ends
    -> m a
withPubSub pub sub = bracket acquire (unsubscribe pub)
  where
    acquire = do
        i <- newInbox =<< sub
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
publisher :: MonadIO m => Publisher event -> STM event -> m ()
publisher pub events = do
    box <- newTVarIO []
    runReaderT go box
  where
    go =
        forever $ do
            incoming <-
                atomically $
                Left <$> receiveSTM pub <|> Right <$> events
            process incoming

process ::
       (MonadIO m, MonadReader (TVar [Inbox event]) m)
    => Either (ControlMsg event) event
    -> m ()
process (Left (Subscribe sub)) = do
    box <- ask
    atomically (modifyTVar box (`union` [sub]))

process (Left (Unsubscribe sub)) = do
    box <- ask
    atomically (modifyTVar box (delete sub))

process (Right event) = do
    box <- ask
    atomically $ do
        subs <- readTVar box
        forM_ subs $ \sub -> do
            full <- mailboxFullSTM sub
            unless full $ event `sendSTM` sub
