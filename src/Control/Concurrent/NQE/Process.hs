{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module Control.Concurrent.NQE.Process where

--
-- Non-blocking asynchronous processes with mailboxes
--

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Reader
import Data.Dynamic

type Mailbox = TQueue Dynamic
type ProcessT = ReaderT Process
type ProcessM = ProcessT IO
type MonadProcess = MonadReader Process

data Handle m   
    = forall a. Typeable a => Case
        { unHandle :: a -> m () }
    | forall a. Typeable a => Filter
        { unFilter :: a -> Bool
        , unHandle :: a -> m ()
        }
    | Default
        { handleDef :: m () }

data Process = Process
    { thread   :: ThreadId
    , mailbox  :: Mailbox
    , links    :: TVar [Process]
    , monitors :: TVar [Process]
    , running  :: TVar (Bool, Maybe SomeException)
    } deriving Typeable

data Signal
    = Stop
    | Linked { linked :: Remote }
    | Kill { killReason :: SomeException }
    deriving (Show, Typeable)

data Remote
    = Finished
        { remoteThread :: ThreadId }
    | Died
        { remoteThread :: ThreadId
        , remoteError  :: SomeException
        }
    deriving (Show, Typeable)
instance Exception Remote

data ProcessException = Stopped
    deriving (Show, Typeable)
instance Exception ProcessException

receiveDynSTM :: ProcessT STM Dynamic
receiveDynSTM = ask >>= \my -> lift $ do
    msg <- readTQueue $ mailbox my
    case fromDynamic msg of
        Just Stop       -> throwSTM Stopped
        Just (Linked l) -> throwSTM l
        Just (Kill s)   -> throwSTM s
        Nothing         -> return msg

startProcess :: ProcessM () -> IO Process
startProcess action = do
    pv <- atomically $ newEmptyTMVar
    tid <- forkFinally (go pv) (cleanup pv)
    atomically $ do
        p <- new tid
        putTMVar pv p
        return p
  where
    new tid = do
        mbox <- newTQueue
        r <- newTVar (True, Nothing)
        ls <- newTVar []
        ms <- newTVar []
        return Process
            { thread   = tid
            , mailbox  = mbox
            , links    = ls
            , monitors = ms
            , running  = r
            }
    go pv = do
        p <- atomically $ readTMVar pv
        runReaderT action p
        return ()
    cleanup pv es = atomically $ do
        p <- readTMVar pv
        ls <- readTVar $ links    p
        ms <- readTVar $ monitors p
        let me = case es of
                Right () -> Nothing
                Left  e  -> Just e
            rm = case me of
                Nothing -> Finished (thread p)
                Just e  -> Died     (thread p) e
        forM_ ls $ flip sendSTM $ Linked rm
        forM_ ms $ flip sendSTM rm
        writeTVar (running p) (False, me)

withProcess :: ProcessM () -> (Process -> IO ()) -> IO ()
withProcess action = bracket (startProcess action) stop

isRunningSTM :: Process -> STM Bool
isRunningSTM = fmap fst . readTVar . running

isRunning :: MonadIO m => Process -> m Bool
isRunning = liftIO . atomically . isRunningSTM

link :: (MonadIO m, MonadProcess m) => Process -> m ()
link proc = ask >>= \my -> liftIO . atomically $ do
    r <- isRunningSTM proc
    if r then add my else dead my
  where
    add my = modifyTVar (links proc) $
        (my:) . filter ((/= thread my) . thread)
    dead my = do
        em <- snd <$> readTVar (running proc)
        sendSTM my $ case em of
            Nothing -> Linked Finished
                { remoteThread = thread proc }
            Just e -> Linked Died
                { remoteThread = thread proc
                , remoteError  = e
                }

unLink :: (MonadIO m, MonadProcess m) => Process -> m ()
unLink proc = ask >>= \my -> liftIO . atomically $
    modifyTVar (links proc) $ filter ((/= thread my) . thread)

monitor :: (MonadIO m, MonadProcess m) => Process -> m ()
monitor proc = ask >>= \my -> liftIO . atomically $ do
    r <- isRunningSTM proc
    if r then add my else dead my
  where
    add my = modifyTVar (monitors proc) $
        (my:) . filter ((/= thread my) . thread)
    dead my = do
        em <- snd <$> readTVar (running proc)
        sendSTM my $ case em of
            Nothing -> Finished
                { remoteThread = thread proc }
            Just e -> Died
                { remoteThread = thread proc
                , remoteError  = e
                }

deMonitor :: (MonadIO m, MonadProcess m) => Process -> m ()
deMonitor proc = ask >>= \my -> liftIO . atomically $
    modifyTVar (monitors proc) $ filter ((/= thread my) . thread)

send :: (MonadIO m, Typeable a) => Process -> a -> m ()
send proc = liftIO . atomically . sendSTM proc

sendSTM :: Typeable a => Process -> a -> STM ()
sendSTM proc = writeTQueue (mailbox proc) . toDyn

waitForSTM :: Process -> STM ()
waitForSTM proc = do
    (r, em) <- readTVar $ running proc
    check $ not r
    case em of
        Nothing -> return ()
        Just e  -> throw  e

waitFor :: MonadIO m => Process -> m ()
waitFor = liftIO . atomically . waitForSTM

receiveDyn :: (MonadIO m, MonadProcess m) => m Dynamic
receiveDyn = ask >>= liftIO . atomically . runReaderT receiveDynSTM

receiveAny :: (MonadProcess m, MonadIO m) => [Handle m] -> m ()
receiveAny hs = ask >>= liftIO . atomically . go [] >>= id
  where
    go xs my = do
        x <- runReaderT receiveDynSTM my
        hndlr <- hnd hs x
        case hndlr of
            Just h  -> requeue xs my >> return h
            Nothing -> go (x:xs) my
    hnd [] _ = return Nothing
    hnd (Case h : ys) x =
        case fromDynamic x of
            Nothing -> hnd ys x
            Just m  -> return $ Just (h m)
    hnd (Filter f h : ys) x =
        case fromDynamic x of
            Nothing -> hnd ys x
            Just m  -> if f m then return $ Just (h m) else hnd hs x
    hnd (Default m : _) _ = return $ Just m
        

requeue :: [Dynamic] -> Process -> STM ()
requeue xs my = forM_ xs $ unGetTQueue $ mailbox my

receiveMatch :: (MonadIO m, MonadProcess m, Typeable a) => (a -> Bool) -> m a
receiveMatch f = ask >>= liftIO . atomically . go []
  where
    go xs my = do
        x <- runReaderT receiveDynSTM my
        case fromDynamic x of
            Nothing -> go (x:xs) my
            Just m  -> if f m then requeue xs my >> return m else go (x:xs) my

receive :: (MonadIO m, MonadProcess m, Typeable a) => m a
receive = receiveMatch (const True)

stop :: MonadIO m => Process -> m ()
stop proc = send proc Stop

kill :: MonadIO m => Process -> SomeException -> m ()
kill proc ex = send proc $ Kill ex
