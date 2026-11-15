{-# LANGUAGE FlexibleContexts #-}

-- |
-- Module      : Control.Concurrent.NQE.Publisher
-- Copyright   : Haskoin Developers
-- License     : MIT
-- Maintainer  : jprupp@protonmail.ch
-- Stability   : experimental
-- Portability : POSIX
--
-- A publisher is a process that forwards messages to subscribers. NQE publishers
-- are simple, and do not implement filtering directly, although that can be done
-- on the 'STM' 'Listen' actions that forward messages to subscribers.
--
-- If a subscriber has been added to a publisher using the 'subscribe' function, it
-- needs to be removed later using 'unsubscribe' when it is no longer needed, or
-- the publisher will continue calling its 'Listen' action in the future, likely
-- causing memory leaks. Prefer 'withSubscription', which unsubscribes
-- automatically.
--
-- = Why a publisher process
--
-- Broadcasting is common: many parts of a program want to hear about the same
-- events, such as new blocks or connected peers, and the code producing them
-- should not need to know who is listening. A publisher decouples the two. The
-- producer sends each event once; subscribers come and go without the producer
-- noticing.
--
-- = Design choices
--
-- * __Subscribers are 'Listen' actions, not inboxes.__ That leaves every policy
--   decision to the subscriber: it can filter events, transform them, drop them
--   when its queue is full, or write them anywhere an 'STM' action can.
--
-- * __Delivery is a single transaction.__ Each event is handed to all current
--   subscribers in one 'STM' transaction, so they all see the same events in the
--   same order. The cost is that one slow 'Listen' action slows the whole
--   publisher, which is why those actions must be quick and must not block.
--
-- * __Unsubscribing cannot be interrupted.__ 'withSubscription' removes its
--   subscriber with asynchronous exceptions blocked, even at the points where
--   'Control.Exception.bracket' alone would let one in. A thread that is being
--   cancelled therefore always unsubscribes, and never leaves behind a
--   subscriber that nobody reads from. The price is that the thread cannot be
--   stopped while it waits to hand over that message, which only happens if
--   the publisher was given a bounded inbox that is full.
--
-- = Example
--
-- @
-- 'withPublisher' $ \\pub ->
--     'withSubscription' pub $ \\inbox -> do
--         'publish' "hello" pub
--         msg <- 'receive' inbox
--         print msg
-- @
module Control.Concurrent.NQE.Publisher
  ( Subscriber,
    PublisherMessage (..),
    Publisher,
    withSubscription,
    subscribe,
    unsubscribe,
    withPublisher,
    publisher,
    publisherProcess,
    publish,
    publishSTM,
  )
where

import Control.Concurrent.NQE.Process
import Control.Concurrent.STM
import Control.Concurrent.Unique
import Control.Exception (bracket, uninterruptibleMask_)
import Control.Monad
import Data.Function
import Data.Hashable
import Data.List

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
  = -- | add a 'Listen' action to the subscriber list, and reply with the
    -- resulting 'Subscriber' handle
    Subscribe !(Listen msg) !(Listen (Subscriber msg))
  | -- | remove a subscriber from the list
    Unsubscribe !(Subscriber msg)
  | -- | forward a message to every subscriber
    Event msg

-- | Alias for a publisher process. Since it is a 'Process', it can be stopped
-- by cancelling its 'getProcessAsync' handle.
type Publisher msg = Process (PublisherMessage msg)

-- | Send a message to all subscribers of a publisher. The message is queued in
-- the publisher's mailbox and forwarded asynchronously.
publish :: msg -> Publisher msg -> IO ()
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
withSubscription :: Publisher msg -> (Inbox msg -> IO a) -> IO a
withSubscription pub f = do
  inbox <- newInbox
  let sub = subscribe pub (`sendSTM` inbox)
      -- Not interruptible, so that a second asynchronous exception cannot
      -- cut the clean-up short and leak the subscriber. 'bracket' from
      -- base only masks its clean-up, which lets an exception in if the
      -- send has to wait. A publisher started by this module has an
      -- unbounded mailbox, so the send does not wait.
      unsub = uninterruptibleMask_ . unsubscribe pub
  bracket sub unsub $ \_ -> f inbox

-- | 'Listen' to events from a publisher. Blocks until the publisher has
-- registered the subscriber, and returns a handle that must later be passed to
-- 'unsubscribe'. The 'Listen' action runs inside the publisher's 'STM'
-- transaction for every event, so it should be fast and must not retry.
subscribe :: Publisher msg -> Listen msg -> IO (Subscriber msg)
subscribe pub sub = Subscribe sub `query` pub

-- | Stop listening to events from a publisher. Must provide 'Subscriber' that
-- was returned from corresponding 'subscribe' action.
unsubscribe :: Publisher msg -> Subscriber msg -> IO ()
unsubscribe pub sub = Unsubscribe sub `send` pub

-- | Start a publisher in the background and pass it to a function. The
-- publisher will be stopped when the function function returns.
withPublisher :: (Publisher msg -> IO a) -> IO a
withPublisher = withProcess publisherProcess

-- | Start a publisher in the background. It must be stopped manually by
-- cancelling 'getProcessAsync'. Prefer 'withPublisher' where possible.
publisher :: IO (Publisher msg)
publisher = process publisherProcess

-- | Start a publisher in the current thread. Runs forever, processing
-- 'PublisherMessage' values from the inbox.
publisherProcess :: Inbox (PublisherMessage msg) -> IO ()
publisherProcess inbox = do
  box <- newTVarIO []
  forever $ receive inbox >>= publisherMessage box

-- | Internal function to dispatch a publisher message. The first argument
-- holds the current subscribers; only the publisher's own thread writes to it.
publisherMessage :: TVar [Subscriber msg] -> PublisherMessage msg -> IO ()
publisherMessage box (Subscribe sub r) = do
  u <- newUnique
  let s = Subscriber sub u
  atomically $ do
    modifyTVar box (`union` [s])
    r s
publisherMessage box (Unsubscribe sub) =
  atomically (modifyTVar box (delete sub))
publisherMessage box (Event event) =
  atomically $
    readTVar box >>= \subs ->
      forM_ subs $ \(Subscriber sub _) -> sub event
