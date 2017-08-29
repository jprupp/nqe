{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE ScopedTypeVariables       #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.Lifted
import           Control.Concurrent.STM
import           Control.Exception.Lifted
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control
import           Data.Maybe

type Mailbox msg = TQueue msg
type Reply a = a -> STM ()
type Listen a = a -> STM ()

data Actor a msg = Actor
    { promise :: !(Async a)
    , mailbox :: !(Mailbox msg)
    } deriving (Eq)

data ActorException
    = ActorNotRunning
    deriving (Show)

instance Exception ActorException

-- | Start an actor.
actor ::
       (MonadBaseControl IO m, MonadIO m, Forall (Pure m))
    => (Actor a msg -> m a) -- ^ actor action
    -> m (Actor a msg)
actor action = do
    mbox <- liftIO newTQueueIO
    abox <- liftIO newEmptyTMVarIO
    a <- async $ atomicallyIO (takeTMVar abox) >>= action
    let act = Actor {promise = a, mailbox = mbox}
    atomicallyIO $ putTMVar abox act
    return act

-- | Run another actor while performing an action in this one. Stop it when
-- action completes.
withActor ::
       (MonadBaseControl IO m, MonadIO m, Forall (Pure m))
    => (Actor a msg -> m a) -- ^ action on actor
    -> (Actor a msg -> m b) -- ^ action on current thread
    -> m b
withActor action go = do
    mbox <- liftIO newTQueueIO
    abox <- liftIO newEmptyTMVarIO
    withAsync (atomicallyIO (takeTMVar abox) >>= action) $ \a -> do
        let act = Actor {promise = a, mailbox = mbox}
        atomicallyIO $ putTMVar abox act
        go act

mailboxEmpty :: MonadIO m => Mailbox msg -> m Bool
mailboxEmpty = atomicallyIO . isEmptyTQueue

send :: MonadIO m => msg -> Mailbox msg -> m ()
send msg mbox = atomicallyIO $ mbox `writeTQueue` msg

query :: MonadIO m => (Reply b -> msg) -> Actor a msg -> m b
query f act = fromMaybe e <$> queryMaybe f act
  where
    e = throw ActorNotRunning

queryMaybe :: MonadIO m => (Reply b -> msg) -> Actor a msg -> m (Maybe b)
queryMaybe f act = do
    box <- atomicallyIO newEmptyTMVar
    f (putTMVar box) `send` mailbox act
    atomicallyIO $
        pollSTM (promise act) >>= \case
            Just _ -> return Nothing
            Nothing -> Just <$> takeTMVar box

requeue :: [msg] -> Mailbox msg -> STM ()
requeue xs mbox = mapM_ (unGetTQueue mbox) xs

extractMsg :: [(msg -> Maybe a, a -> m b)] -> Mailbox msg -> STM (m b)
extractMsg hs mbox = do
    msg <- readTQueue mbox
    go [] msg hs
  where
    go acc msg [] = do
        msg' <- readTQueue mbox
        go (msg : acc) msg' hs
    go acc msg ((f, action):fs) =
        case f msg of
            Just x -> do
                requeue acc mbox
                return $ action x
            Nothing -> go acc msg fs

dispatch ::
       (MonadBase IO m, MonadIO m)
    => [(msg -> Maybe a, a -> m b)] -- ^ action to dispatch
    -> Mailbox msg -- ^ mailbox to read from
    -> m b
dispatch hs = join . atomicallyIO . extractMsg hs

receive :: (MonadBase IO m, MonadIO m) => Mailbox msg -> m msg
receive = dispatch [(Just, return)]

receiveMatch ::
       (MonadBase IO m, MonadIO m) => Mailbox msg -> (msg -> Maybe a) -> m a
receiveMatch mbox f = dispatch [(f, return)] mbox

atomicallyIO :: MonadIO m => STM a -> m a
atomicallyIO = liftIO . atomically

timeout :: (MonadBaseControl IO m, Forall (Pure m)) => Int -> m a -> m (Maybe a)
timeout n action = race (threadDelay n) action >>= \case
    Left () -> return Nothing
    Right r -> return $ Just r
