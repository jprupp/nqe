{-# LANGUAGE FlexibleContexts           #-}
{-|
Module      : Control.Concurrent.NQE.Publisher
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

A publisher is a process that forwards messages to subscribers. NQE publishers
are simple, and do not implement filtering directly, although that can be done
on the 'STM' 'Listen' actions that forward messages to subscribers.

If a subscriber has been added to a publisher using the 'subscribe' function, it
needs to be removed later using 'unsubscribe' when it is no longer needed, or
the publisher will continue calling its 'Listen' action in the future, likely
causing memory leaks.
-}
module Control.Concurrent.NQE.Publisher
    ( Subscriber
    , PublisherMessage(..)
    , Publisher
    , withSubscription
    , subscribe
    , unsubscribe
    , withPublisher
    , publisher
    , publisherProcess
    ) where

import           Control.Concurrent.NQE.Process
import           Control.Concurrent.Unique
import           Control.Monad.Reader
import           Data.Function
import           Data.Hashable
import           Data.List
import           UnliftIO

-- | Handle of a subscriber to a process. Should be kept in order to
-- unsubscribe.
data Subscriber msg = Subscriber (Listen msg) Unique

instance Eq (Subscriber msg) where
    (==) = (==) `on` f
      where
        f (Subscriber _ u) = u

instance Hashable (Subscriber msg) where
    hashWithSalt i (Subscriber _ u) = hashWithSalt i u

-- | Messages that a publisher will take.
data PublisherMessage msg
    = Subscribe !(Listen msg) !(Listen (Subscriber msg))
    | Unsubscribe !(Subscriber msg)
    | Event msg

-- | Alias for a publisher process.
type Publisher msg = Process (PublisherMessage msg)

-- | Create a mailbox, subscribe it to a publisher and pass it to the supplied
-- function . End subscription when function returns.
withSubscription ::
       MonadUnliftIO m => Publisher msg -> (Inbox msg -> m a) -> m a
withSubscription pub f = do
    inbox <- newInbox
    let sub = subscribe pub (`sendSTM` inbox)
        unsub = unsubscribe pub
    bracket sub unsub $ \_ -> f inbox

-- | 'Listen' to events from a publisher.
subscribe :: MonadIO m => Publisher msg -> Listen msg -> m (Subscriber msg)
subscribe pub sub = Subscribe sub `query` pub

-- | Stop listening to events from a publisher. Must provide 'Subscriber' that
-- was returned from corresponding 'subscribe' action.
unsubscribe :: MonadIO m => Publisher msg -> Subscriber msg -> m ()
unsubscribe pub sub = Unsubscribe sub `send` pub

-- | Start a publisher in the background and pass it to a function. The
-- publisher will be stopped when the function function returns.
withPublisher :: MonadUnliftIO m => (Publisher msg -> m a) -> m a
withPublisher = withProcess publisherProcess

-- | Start a publisher in the background.
publisher :: MonadUnliftIO m => m (Publisher msg)
publisher = process publisherProcess

-- | Start a publisher in the current thread.
publisherProcess :: MonadUnliftIO m => Inbox (PublisherMessage msg) -> m ()
publisherProcess inbox = newTVarIO [] >>= runReaderT go
  where
    go = forever $ receive inbox >>= publisherMessage

-- | Internal function to dispatch a publisher message.
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
