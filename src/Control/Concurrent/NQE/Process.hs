{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent
import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control

type Reply a = a -> STM ()
type Listen a = a -> STM ()

class Mailbox mbox where
    mailboxEmptySTM :: mbox msg -> STM Bool
    sendSTM :: msg -> mbox msg -> STM ()
    receiveSTM :: mbox msg -> STM msg
    requeueMsg :: msg -> mbox msg -> STM ()

instance Mailbox TQueue where
    mailboxEmptySTM = isEmptyTQueue
    sendSTM msg = (`writeTQueue` msg)
    receiveSTM = readTQueue
    requeueMsg msg = (`unGetTQueue` msg)

instance Mailbox TBQueue where
    mailboxEmptySTM = isEmptyTBQueue
    sendSTM msg = (`writeTBQueue` msg)
    receiveSTM = readTBQueue
    requeueMsg msg = (`unGetTBQueue` msg)

data Inbox msg =
    forall mbox. (Mailbox mbox) =>
                 Inbox (mbox msg)

instance Mailbox Inbox where
    mailboxEmptySTM (Inbox mbox) = mailboxEmptySTM mbox
    sendSTM msg (Inbox mbox) = msg `sendSTM` mbox
    receiveSTM (Inbox mbox) = receiveSTM mbox
    requeueMsg msg (Inbox mbox) = msg `requeueMsg` mbox

mailboxEmpty :: (MonadIO m, Mailbox mbox) => mbox msg -> m Bool
mailboxEmpty = liftIO . atomically . mailboxEmptySTM

send :: (MonadIO m, Mailbox mbox) => msg -> mbox msg -> m ()
send msg = liftIO . atomically . sendSTM msg

requeue :: (Mailbox mbox) => [msg] -> mbox msg -> STM ()
requeue xs mbox = mapM_ (`requeueMsg` mbox) xs

extractMsg ::
       (Mailbox mbox)
    => [(msg -> Maybe a, a -> b)]
    -> mbox msg
    -> STM b
extractMsg hs mbox = do
    msg <- receiveSTM mbox
    go [] msg hs
  where
    go acc msg [] = do
        msg' <- receiveSTM mbox
        go (msg : acc) msg' hs
    go acc msg ((f, action):fs) =
        case f msg of
            Just x -> do
                requeue acc mbox
                return $ action x
            Nothing -> go acc msg fs

query ::
       (MonadIO m, Mailbox mbox)
    => (Reply b -> msg)
    -> mbox msg
    -> m b
query f mbox = do
    box <- liftIO $ atomically newEmptyTMVar
    f (putTMVar box) `send` mbox
    liftIO . atomically $ takeTMVar box

dispatch ::
       (MonadIO m, Mailbox mbox)
    => [(msg -> Maybe a, a -> IO b)] -- ^ action to dispatch
    -> mbox msg -- ^ mailbox to read from
    -> m b
dispatch hs = liftIO . join . atomically . extractMsg hs

dispatchSTM :: (Mailbox mbox) => [msg -> Maybe a] -> mbox msg -> STM a
dispatchSTM = extractMsg . map (\x -> (x, id))

receive ::
       (MonadIO m, Mailbox mbox)
    => mbox msg
    -> m msg
receive = dispatch [(Just, return)]

receiveMatch :: (MonadIO m, Mailbox mbox) => mbox msg -> (msg -> Maybe a) -> m a
receiveMatch mbox f = dispatch [(f, return)] mbox

receiveMatchSTM :: (Mailbox mbox) => mbox msg -> (msg -> Maybe a) -> STM a
receiveMatchSTM mbox f = dispatchSTM [f] mbox

timeout ::
       forall m b. (MonadIO m, MonadBaseControl IO m, Forall (Pure m))
    => Int
    -> m b
    -> m (Maybe b)
timeout n action =
    race (liftIO $ threadDelay n) action >>= \case
        Left () -> return Nothing
        Right r -> return $ Just r
