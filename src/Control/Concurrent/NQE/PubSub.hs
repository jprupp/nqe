{-# LANGUAGE FlexibleContexts #-}
module Control.Concurrent.NQE.PubSub (publisher, withPubSub) where

import           Control.Applicative
import           Control.Concurrent.NQE.Process
import           Control.Monad.Reader
import           Data.List
import           UnliftIO

data ControlMsg msg
    = Subscribe (TQueue msg)
    | Unsubscribe (TQueue msg)

data Incoming msg
    = Control (ControlMsg msg)
    | Event msg

type Publisher mbox msg = mbox (ControlMsg msg)

withPubSub ::
       (MonadUnliftIO m, Mailbox mbox)
    => Publisher mbox msg
    -> (Inbox msg -> m a)
    -> m a
withPubSub pub f = bracket subscribe unsubscribe action
  where
    subscribe = do
        mbox <- newTQueueIO
        Subscribe mbox `send` pub
        return mbox
    unsubscribe mbox = Unsubscribe mbox `send` pub
    action mbox = f (Inbox mbox)

publisher ::
       ( MonadIO m
       , Mailbox mbox
       , Mailbox events
       )
    => Publisher mbox msg
    -> events msg
    -> m ()
publisher pub events = do
    box <- newTVarIO []
    runReaderT go box
  where
    go =
        forever $ do
            incoming <-
                atomically $
                Control <$> receiveSTM pub <|> Event <$> receiveSTM events
            process incoming

process ::
       (MonadIO m, MonadReader (TVar [TQueue msg]) m) => Incoming msg -> m ()
process (Control (Subscribe mbox)) = do
    box <- ask
    atomically $ do
        subscribers <- readTVar box
        when (mbox `notElem` subscribers) $
            writeTVar box (mbox : subscribers)

process (Control (Unsubscribe mbox)) = do
    box <- ask
    atomically (modifyTVar box (delete mbox))

process (Event event) = do
    box <- ask
    readTVarIO box >>= mapM_ (send event)
