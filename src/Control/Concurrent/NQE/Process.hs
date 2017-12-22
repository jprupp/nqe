{-# LANGUAGE LambdaCase #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent.Async
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Monad

type Reply a = a -> STM ()
type Listen a = a -> STM ()
type Actor a = Async a

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

-- | Start an actor.
actor ::
       IO a -- ^ actor action
    -> IO (Async a)
actor = async

-- | Run another actor while performing an action on this thread. Stop it when
-- action completes. Remote actor is linked to current thread.
withActor ::
       IO a -- ^ action on actor
    -> (Actor a -> IO b) -- ^ action on current thread
    -> IO b
withActor = withAsync

mailboxEmpty :: (Mailbox mbox) => mbox msg -> IO Bool
mailboxEmpty = atomically . mailboxEmptySTM

send :: (Mailbox mbox) => msg -> mbox msg -> IO ()
send msg = atomically . sendSTM msg

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
       (Mailbox mbox)
    => (Reply b -> msg)
    -> mbox msg
    -> IO b
query f mbox = do
    box <- atomically newEmptyTMVar
    f (putTMVar box) `send` mbox
    atomically $ takeTMVar box

dispatch ::
       (Mailbox mbox)
    => [(msg -> Maybe a, a -> IO b)] -- ^ action to dispatch
    -> mbox msg -- ^ mailbox to read from
    -> IO b
dispatch hs = join . atomically . extractMsg hs

dispatchSTM :: (Mailbox mbox) => [msg -> Maybe a] -> mbox msg -> STM a
dispatchSTM = extractMsg . map (\x -> (x, id))

receive ::
       (Mailbox mbox)
    => mbox msg
    -> IO msg
receive = dispatch [(Just, return)]

receiveMatch :: (Mailbox mbox) => mbox msg -> (msg -> Maybe a) -> IO a
receiveMatch mbox f = dispatch [(f, return)] mbox

receiveMatchSTM :: (Mailbox mbox) => mbox msg -> (msg -> Maybe a) -> STM a
receiveMatchSTM mbox f = dispatchSTM [f] mbox

timeout :: Int -> IO a -> IO (Maybe a)
timeout n action =
    race (threadDelay n) action >>= \case
        Left () -> return Nothing
        Right r -> return $ Just r
