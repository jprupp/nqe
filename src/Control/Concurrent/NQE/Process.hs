{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE ScopedTypeVariables       #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.Lifted
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control

type Mailbox mbox msg = mbox msg
type Reply a = a -> STM ()
type Listen a = a -> STM ()
type Actor a = Async a

class ActorMailbox mbox where
    mailboxEmptySTM :: Mailbox mbox msg -> STM Bool
    sendSTM :: msg -> Mailbox mbox msg -> STM ()
    receiveSTM :: Mailbox mbox msg -> STM msg
    requeueMsg :: msg -> Mailbox mbox msg -> STM ()

instance ActorMailbox TQueue where
    mailboxEmptySTM = isEmptyTQueue
    sendSTM msg = (`writeTQueue` msg)
    receiveSTM = readTQueue
    requeueMsg msg = (`unGetTQueue` msg)

instance ActorMailbox TBQueue where
    mailboxEmptySTM = isEmptyTBQueue
    sendSTM msg = (`writeTBQueue` msg)
    receiveSTM = readTBQueue
    requeueMsg msg = (`unGetTBQueue` msg)

-- | Start an actor.
actor ::
       (MonadBaseControl IO m, MonadIO m, Forall (Pure m))
    => m a -- ^ actor action
    -> m (Async a)
actor = async

-- | Run another actor while performing an action on this thread. Stop it when
-- action completes. Remote actor is linked to current thread.
withActor ::
       (MonadBaseControl IO m, MonadIO m, Forall (Pure m))
    => m a -- ^ action on actor
    -> (Actor a -> m b) -- ^ action on current thread
    -> m b
withActor = withAsync

mailboxEmpty :: (ActorMailbox mbox, MonadIO m) => Mailbox mbox msg -> m Bool
mailboxEmpty = atomicallyIO . mailboxEmptySTM

send :: (ActorMailbox mbox, MonadIO m) => msg -> Mailbox mbox msg -> m ()
send msg = atomicallyIO . sendSTM msg

requeue :: (ActorMailbox mbox) => [msg] -> Mailbox mbox msg -> STM ()
requeue xs mbox = mapM_ (`requeueMsg` mbox) xs

extractMsg ::
       (ActorMailbox mbox)
    => [(msg -> Maybe a, a -> b)]
    -> Mailbox mbox msg
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
       (ActorMailbox mbox, MonadIO m)
    => (Reply b -> msg)
    -> Mailbox mbox msg
    -> m b
query f mbox = do
    box <- atomicallyIO newEmptyTMVar
    f (putTMVar box) `send` mbox
    atomicallyIO $ takeTMVar box

dispatch ::
       (ActorMailbox mbox, MonadBase IO m, MonadIO m)
    => [(msg -> Maybe a, a -> m b)] -- ^ action to dispatch
    -> Mailbox mbox msg -- ^ mailbox to read from
    -> m b
dispatch hs = join . atomicallyIO . extractMsg hs

dispatchSTM :: (ActorMailbox mbox) => [msg -> Maybe a] -> Mailbox mbox msg -> STM a
dispatchSTM = extractMsg . map (\x -> (x, id))

receive ::
       (ActorMailbox mbox, MonadBase IO m, MonadIO m)
    => Mailbox mbox msg
    -> m msg
receive = dispatch [(Just, return)]

receiveMatch ::
       (ActorMailbox mbox, MonadBase IO m, MonadIO m)
    => Mailbox mbox msg
    -> (msg -> Maybe a)
    -> m a
receiveMatch mbox f = dispatch [(f, return)] mbox

receiveMatchSTM ::
       (ActorMailbox mbox) => Mailbox mbox msg -> (msg -> Maybe a) -> STM a
receiveMatchSTM mbox f = dispatchSTM [f] mbox

atomicallyIO :: MonadIO m => STM a -> m a
atomicallyIO = liftIO . atomically

timeout :: (MonadBaseControl IO m, Forall (Pure m)) => Int -> m a -> m (Maybe a)
timeout n action = race (threadDelay n) action >>= \case
    Left () -> return Nothing
    Right r -> return $ Just r
