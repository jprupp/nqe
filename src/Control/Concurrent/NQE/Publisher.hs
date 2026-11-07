{-# LANGUAGE FlexibleContexts           #-}
{-|
Module      : Control.Concurrent.NQE.Publisher
Copyright   : Haskoin Developers
License     : MIT
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

A publisher is a process that forwards messages to subscribers. NQE publishers
are simple, and do not implement filtering directly, although that can be done
on the 'STM' 'Listen' actions that forward messages to subscribers.

If a subscriber has been added to a publisher using the 'subscribe' function, it
needs to be removed later using 'unsubscribe' when it is no longer needed, or
the publisher will continue calling its 'Listen' action in the future, likely
causing memory leaks. Prefer 'withSubscription', which unsubscribes
automatically.

= Why a publisher process

Broadcasting is common: many parts of a program want to hear about the same
events, such as new blocks or connected peers, and the code producing them
should not need to know who is listening. A publisher decouples the two. The
producer sends each event once; subscribers come and go without the producer
noticing.

= Design choices

* __Subscribers are 'Listen' actions, not inboxes.__ That leaves every policy
  decision to the subscriber: it can filter events, transform them, drop them
  when its queue is full, or write them anywhere an 'STM' action can.

* __Delivery is a single transaction.__ Each event is handed to all current
  subscribers in one 'STM' transaction, so they all see the same events in the
  same order. The cost is that one slow 'Listen' action slows the whole
  publisher, which is why those actions must be quick and must not block.

* __The loop is flat.__ The publisher loop sequences with @>>=@ rather than
  'Control.Monad.forever', so that it runs in constant memory even in monads
  like @LoggingT@, where @forever@ leaks.

= Example

@
'withPublisher' $ \\pub ->
    'withSubscription' pub $ \\inbox -> do
        'publish' "hello" pub
        msg <- 'receive' inbox
        print msg
@
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
    , publish
    , publishSTM
    ) where

import           Control.Concurrent.NQE.Process
import           Control.Concurrent.Unique
import           Control.Monad
import           Control.Monad.Reader
import           Data.Function
import           Data.Hashable
import           Data.List
import           UnliftIO

-- | Handle of a subscriber to a process. Should be kept in order to
-- unsubscribe. Subscribers are compared by a 'Unique' identifier assigned by the
-- publisher when they subscribe.
data Subscriber msg = Subscriber (Listen msg) Unique

instance Eq (Subscriber msg) where
    (==) = (==) `on` f
      where
        f (Subscriber _ u) = u

instance Hashable (Subscriber msg) where
    hashWithSalt i (Subscriber _ u) = hashWithSalt i u

-- | Messages that a publisher will take. Normally these are not built
-- directly; use 'subscribe', 'unsubscribe' and 'publish' instead.
data PublisherMessage msg
    = Subscribe !(Listen msg) !(Listen (Subscriber msg))
      -- ^ add a 'Listen' action to the subscriber list, and reply with the
      -- resulting 'Subscriber' handle
    | Unsubscribe !(Subscriber msg)
      -- ^ remove a subscriber from the list
    | Event msg
      -- ^ forward a message to every subscriber

-- | Alias for a publisher process. Since it is a 'Process', it can be stopped
-- by cancelling its 'getProcessAsync' handle.
type Publisher msg = Process (PublisherMessage msg)

-- | Send a message to all subscribers of a publisher. The message is queued in
-- the publisher's mailbox and forwarded asynchronously.
publish :: MonadIO m => msg -> Publisher msg -> m ()
publish = send . Event

-- | 'STM' version of 'publish'. Useful to publish a message atomically together
-- with other 'STM' actions.
publishSTM :: msg -> Publisher msg -> STM ()
publishSTM = sendSTM . Event

-- | Create a mailbox, subscribe it to a publisher and pass it to the supplied
-- function. End subscription when function returns, even if it throws an
-- exception. The inbox is unbounded, so the caller should consume messages from
-- it regularly to avoid unbounded memory growth.
--
-- This is the safe way to subscribe, because the subscription cannot outlive
-- the scope. For a bounded or filtered subscription, write your own bracket
-- around 'subscribe' and 'unsubscribe' with your own 'Listen' action.
withSubscription ::
       MonadUnliftIO m => Publisher msg -> (Inbox msg -> m a) -> m a
withSubscription pub f = do
    inbox <- newInbox
    let sub = subscribe pub (`sendSTM` inbox)
        unsub = unsubscribe pub
    bracket sub unsub $ \_ -> f inbox

-- | 'Listen' to events from a publisher. Blocks until the publisher has
-- registered the subscriber, and returns a handle that must later be passed to
-- 'unsubscribe'. The 'Listen' action runs inside the publisher's 'STM'
-- transaction for every event, so it should be fast and must not retry.
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

-- | Start a publisher in the background. It must be stopped manually by
-- cancelling 'getProcessAsync'. Prefer 'withPublisher' where possible.
publisher :: MonadUnliftIO m => m (Publisher msg)
publisher = process publisherProcess

-- | Start a publisher in the current thread. Runs forever, processing
-- 'PublisherMessage' values from the inbox.
publisherProcess :: MonadUnliftIO m => Inbox (PublisherMessage msg) -> m ()
publisherProcess inbox = newTVarIO [] >>= runReaderT go
  where
    -- Sequenced with (>>=) only: 'forever' uses (*>), which for a monad
    -- that is only known through its dictionary (LoggingT in particular)
    -- leaves a continuation frame and two thunks per message, forever.
    go = receive inbox >>= publisherMessage >>= \_ -> go

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
