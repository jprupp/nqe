{-# LANGUAGE FlexibleContexts #-}
module Control.Concurrent.NQE.PubSub
    ( Publisher
    , publisher
    , boundedPublisher
    , withPubSub
    , withBoundedPubSub
    ) where

import           Control.Applicative
import           Control.Concurrent.NQE.Process
import           Control.Monad.Reader
import           Data.List
import           UnliftIO

data ControlMsg ch msg
    = Subscribe (ch msg)
    | Unsubscribe (ch msg)

data Incoming ch msg
    = Control (ControlMsg ch msg)
    | Event msg

type Publisher mbox ch msg = mbox (ControlMsg ch msg)

withPubSub ::
       (MonadUnliftIO m, Mailbox mbox)
    => Publisher mbox TQueue msg
    -> (TQueue msg -> m a)
    -> m a
withPubSub pub f = bracket subscribe unsubscribe action
  where
    subscribe = do
        mbox <- newTQueueIO
        Subscribe mbox `send` pub
        return mbox
    unsubscribe mbox = Unsubscribe mbox `send` pub
    action mbox = f mbox

withBoundedPubSub ::
       (MonadUnliftIO m, Mailbox mbox)
    => Int
    -> Publisher mbox TBQueue msg
    -> (TBQueue msg -> m a)
    -> m a
withBoundedPubSub bound pub f = bracket subscribe unsubscribe action
  where
    subscribe = do
        mbox <- newTBQueueIO bound
        Subscribe mbox `send` pub
        return mbox
    unsubscribe mbox = Unsubscribe mbox `send` pub
    action mbox = f mbox

publisher ::
       ( MonadIO m
       , Mailbox mbox
       , Mailbox events
       , Mailbox ch
       , Eq (ch msg)
       )
    => Publisher mbox ch msg
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

boundedPublisher ::
       (MonadIO m, Mailbox mbox, Mailbox events)
    => Publisher mbox TBQueue msg
    -> events msg
    -> m ()
boundedPublisher pub events = do
    box <- newTVarIO []
    runReaderT go box
  where
    go =
        forever $ do
        incoming <-
            atomically $
            Control <$> receiveSTM pub <|> Event <$> receiveSTM events
        processBound incoming

processBound ::
       (MonadIO m, MonadReader (TVar [TBQueue msg]) m)
    => Incoming TBQueue msg
    -> m ()
processBound (Control (Subscribe mbox)) = do
    box <- ask
    atomically $ do
        subscribers <- readTVar box
        when (mbox `notElem` subscribers) $ writeTVar box (mbox : subscribers)

processBound (Control (Unsubscribe mbox)) = do
    box <- ask
    atomically (modifyTVar box (delete mbox))

processBound (Event event) =
    ask >>= \box ->
        atomically $
        readTVar box >>= \subs ->
            forM_ subs $ \sub ->
                isFullTBQueue sub >>= \full ->
                    when (not full) (event `sendSTM` sub)

process ::
       (Eq (ch msg), Mailbox ch, MonadIO m, MonadReader (TVar [ch msg]) m)
    => Incoming ch msg
    -> m ()
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
