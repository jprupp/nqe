{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Control.Concurrent.NQE.Publisher where

import           Control.Concurrent.NQE.Process
import           Control.Monad.Reader
import           Data.Dynamic
import           Data.Hashable
import           Data.List
import           UnliftIO

-- | Subscribe or unsubscribe from an event publisher.
data PublisherMessage
    = Subscribe !Mailbox
    | Unsubscribe !Mailbox

-- | Publisher process wrapper.
newtype Publisher = Publisher Process
    deriving (Eq, Hashable, OutChan)

-- | Subscribe a 'Mailbox' to a 'Publisher' generating events.
subscribe :: MonadIO m => Publisher -> Mailbox -> m ()
subscribe pub sub = Subscribe sub `send` pub

-- | Unsubscribe an 'Inbox' from a 'Publisher' events.
unsubscribe :: MonadIO m => Publisher -> Mailbox -> m ()
unsubscribe pub sub = Unsubscribe sub `send` pub

-- | Launch a 'Publisher'. The publisher will be stopped when the associated
-- action stops.
withPublisher :: MonadUnliftIO m => (Publisher -> m a) -> m a
withPublisher f = withProcess publisherProcess $ f . Publisher

-- | Launch a 'Publisher'.
publisher :: MonadUnliftIO m => m Publisher
publisher = Publisher <$> process publisherProcess

-- | Start a 'Publisher' that will forward events to subscribers.
publisherProcess :: MonadUnliftIO m => Inbox -> m ()
publisherProcess pub = newTVarIO [] >>= runReaderT go
  where
    go = forever $ dispatch (Just forwardEvent) pub [Dispatch processControl]

-- | Internal function to dispatch a received control message.
processControl ::
       (MonadIO m, MonadReader (TVar [Mailbox]) m) => PublisherMessage -> m ()
processControl (Subscribe sub) =
    ask >>= \box -> atomically (modifyTVar box (`union` [sub]))

processControl (Unsubscribe sub) =
    ask >>= \box -> atomically (modifyTVar box (delete sub))

-- | Internal function to forward events to all subscribed mailboxes.
forwardEvent :: (MonadIO m, MonadReader (TVar [Mailbox]) m) => Dynamic -> m ()
forwardEvent event =
    ask >>= \box ->
        atomically $
        readTVar box >>= \subs ->
            forM_ subs $ \sub -> do
                full <- mailboxFullSTM sub
                unless full $ event `sendDynSTM` sub
