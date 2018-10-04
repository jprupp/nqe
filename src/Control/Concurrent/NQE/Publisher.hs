{-# LANGUAGE FlexibleContexts           #-}
module Control.Concurrent.NQE.Publisher where

import           Control.Concurrent.NQE.Process
import           Control.Concurrent.Unique
import           Control.Monad.Reader
import           Data.Function
import           Data.Hashable
import           Data.List
import           UnliftIO

data Subscriber msg = Subscriber (Listen msg) Unique

instance Eq (Subscriber msg) where
    (==) = (==) `on` f
      where
        f (Subscriber _ u) = u

instance Hashable (Subscriber msg) where
    hashWithSalt i (Subscriber _ u) = hashWithSalt i u

-- | Subscribe or unsubscribe from an event publisher.
data PublisherMessage msg
    = Subscribe !(Listen msg) !(Listen (Subscriber msg))
    | Unsubscribe !(Subscriber msg)
    | Event msg

-- | Publisher process wrapper.
type Publisher msg = Process (PublisherMessage msg)

-- | Create a mailbox and subscribe to a publisher. End subscription when
-- associated action ends.
withSubscription ::
       MonadUnliftIO m => Publisher msg -> (Inbox msg -> m a) -> m a
withSubscription pub f = do
    inbox <- newInbox
    let sub = subscribe pub (`sendSTM` inbox)
        unsub = unsubscribe pub
    bracket sub unsub $ \_ -> f inbox

-- | 'Listen' to a 'Publisher' generating events.
subscribe :: MonadIO m => Publisher msg -> Listen msg -> m (Subscriber msg)
subscribe pub sub = Subscribe sub `query` pub

-- | Unsubscribe from a 'Publisher' events.
unsubscribe :: MonadIO m => Publisher msg -> Subscriber msg -> m ()
unsubscribe pub sub = Unsubscribe sub `send` pub

-- | Launch a 'Publisher'. The publisher will be stopped when the associated
-- action ends.
withPublisher :: MonadUnliftIO m => (Publisher msg -> m a) -> m a
withPublisher = withProcess publisherProcess

-- | Launch a 'Publisher'.
publisher :: MonadUnliftIO m => m (Publisher msg)
publisher = process publisherProcess

-- | Start a 'Publisher' that will forward events to subscribers.
publisherProcess :: MonadUnliftIO m => Inbox (PublisherMessage msg) -> m ()
publisherProcess inbox = newTVarIO [] >>= runReaderT go
  where
    go = forever $ receive inbox >>= publisherMessage

-- | Internal function to dispatch a received control message.
publisherMessage ::
       (MonadIO m, MonadReader (TVar [Subscriber msg]) m)
    => PublisherMessage msg
    -> m ()
publisherMessage (Subscribe sub r) =
    ask >>= \box -> do
        u <- liftIO newUnique
        let s = Subscriber sub u
        atomically $ do
            modifyTVar box (`union` [s])
            r s

publisherMessage (Unsubscribe sub) =
    ask >>= \box -> atomically (modifyTVar box (delete sub))

publisherMessage (Event event) =
    ask >>= \box ->
        atomically $
        readTVar box >>= \subs ->
            forM_ subs $ \(Subscriber sub _) -> sub event
