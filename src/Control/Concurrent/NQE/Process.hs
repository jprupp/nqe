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
import Data.List

type Mailbox = TQueue Dynamic
type ProcessT = ReaderT Process
type ProcessM = ProcessT IO
type MonadProcess = MonadReader Process

data Handle m   
    = forall a. Typeable a =>
      Case { unHandle :: a -> m () }
    | forall a. Typeable a =>
      Filter { unFilter :: a -> Bool
             , unHandle :: a -> m ()
             }
    | Default { handleDef :: m () }

data ProcessSpec = ProcessSpec
    { provides :: Maybe String
    , depends  :: [String]
    , action   :: ProcessM ()
    } deriving (Typeable)

data Process = Process
    { name     :: Maybe String
    , thread   :: ThreadId
    , mailbox  :: Mailbox
    , procs    :: TVar [Process]
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

data ProcessException
    = Stopped
    | DependencyNotFound String
    | DependencyNotRunning String
    deriving (Eq, Show, Typeable)
instance Exception ProcessException

receiveDynSTM :: ProcessT STM Dynamic
receiveDynSTM = myProcess >>= \me -> lift $ do
    msg <- readTQueue $ mailbox me
    case fromDynamic msg of
        Just Stop       -> throwSTM Stopped
        Just (Linked l) -> throwSTM l
        Just (Kill s)   -> throwSTM s
        Nothing         -> return msg

startProcess :: ProcessSpec -> ProcessM Process
startProcess s = do
    parent <- myProcess
    liftIO $ do
        (pbox, tbox) <- atomically $
            (,) <$> newEmptyTMVar <*> newEmptyTMVar
        tid <-
            forkFinally
            (go pbox tbox parent)
            (cleanup pbox parent)
        atomically $ putTMVar tbox tid
        atomically $ readTMVar pbox
  where
    new tid parent = do
        mbox <- newTQueue
        run  <- newTVar (True, Nothing)
        mons <- newTVar []
        lns  <- newTVar []
        deps <- forM (nub $ depends s) $ \dep -> do
            mp <- getProcessSTM dep parent
            case mp of
                Nothing -> throwSTM $ DependencyNotFound dep
                Just p -> isRunningSTM p >>= \alive ->
                    if alive
                    then return p
                    else throwSTM $ DependencyNotRunning dep
        pcs  <- newTVar deps
        let proc = Process
                { name     = provides s
                , thread   = tid
                , mailbox  = mbox
                , procs    = pcs
                , links    = lns
                , monitors = mons
                , running  = run
                }
        forM_ deps $ linkSTM proc
        case provides s of
            Nothing -> return ()
            Just  _ -> modifyTVar (procs parent) $ (proc :)
        return proc
    go pbox tbox parent = do
        proc <- atomically $ do
            tid  <- readTMVar tbox
            proc <- new tid parent
            putTMVar pbox proc
            return proc
        runReaderT (action s) proc
    cleanup pbox parent es = atomically $ do
        proc@Process
            { thread   = tid
            , links    = lbox
            , monitors = mbox
            , running  = rbox
            } <- readTMVar pbox
        ls <- readTVar lbox
        ms <- readTVar mbox
        let rm = case es of
                Right _ -> Finished (thread proc)
                Left  e -> Died (thread proc) e
        forM_ ls $ flip sendSTM $ Linked rm
        forM_ ms $ flip sendSTM rm
        modifyTVar (procs parent) $ filter ((/= tid) . thread)
        writeTVar rbox (False, either Just (const Nothing) es)

withProcess
    :: ProcessSpec
    -> (Process -> ProcessM a)
    -> ProcessM a
withProcess spec act = do
    me <- myProcess
    liftIO $
        bracket
        (runReaderT (startProcess spec) me)
        stop
        (go me)
  where
    go me p = runReaderT (act p) me

asProcess
    :: MonadIO m
    => Maybe String
    -> [Process]
    -> ProcessT m a
    -> m a
asProcess mname deps act = do
    tid <- liftIO myThreadId
    proc <- liftIO $ atomically $ do
        mbox <- newTQueue
        run  <- newTVar (True, Nothing)
        mons <- newTVar []
        lns  <- newTVar []
        prcs <- newTVar deps
        return $ Process
            { name     = mname
            , thread   = tid
            , mailbox  = mbox
            , procs    = prcs
            , links    = lns
            , monitors = mons
            , running  = run
            }
    runReaderT act proc

isRunningSTM :: Process -> STM Bool
isRunningSTM Process{ running = rbox } = fst <$> readTVar rbox

isRunning :: MonadIO m => Process -> m Bool
isRunning = liftIO . atomically . isRunningSTM

linkSTM :: Process -> Process -> STM ()
linkSTM me proc = do
    r <- isRunningSTM proc
    if r then add else dead
  where
    add = modifyTVar (links proc) $ (me :) . filter remove
    remove p = thread me /= thread p
    dead = do
        merr <- snd <$> readTVar (running proc)
        sendSTM me $ case merr of
            Nothing -> Linked Finished
                { remoteThread = thread proc }
            Just  e -> Linked Died
                { remoteThread = thread proc
                , remoteError  = e
                }

link :: (MonadIO m, MonadProcess m) => Process -> m ()
link proc = myProcess >>= \me -> liftIO . atomically $ linkSTM me proc

unLink :: (MonadIO m, MonadProcess m) => Process -> m ()
unLink proc = do
    me <- myProcess
    liftIO . atomically $
        modifyTVar (links proc) $ filter (remove me)
  where
    remove me p = thread me /= thread p

monitor :: (MonadIO m, MonadProcess m) => Process -> m ()
monitor proc = do
    me <- myProcess
    liftIO . atomically $ do
        r <- isRunningSTM proc
        if r then add me else dead me
  where
    add me = modifyTVar (monitors proc) $
        (me :) . filter (remove me)
    remove me p = thread me /= thread p
    dead me = do
        merr <- snd <$> readTVar (running proc)
        sendSTM me $ case merr of
            Nothing -> Finished
                { remoteThread = thread proc }
            Just  e -> Died
                { remoteThread = thread proc
                , remoteError  = e
                }

deMonitor :: (MonadIO m, MonadProcess m) => Process -> m ()
deMonitor proc = do
    me <- myProcess
    liftIO . atomically $
        modifyTVar (monitors proc) $ filter (remove me)
  where
    remove me p = thread me /= thread p

send :: (MonadIO m, Typeable msg) => Process -> msg -> m ()
send proc = liftIO . atomically . sendSTM proc

sendSTM :: Typeable msg => Process -> msg -> STM ()
sendSTM proc = writeTQueue (mailbox proc) . toDyn

waitForSTM :: Process -> STM ()
waitForSTM p = readTVar (running p) >>= check . not . fst

waitFor :: MonadIO m => Process -> m ()
waitFor = liftIO . atomically . waitForSTM

receiveDyn :: (MonadIO m, MonadProcess m) => m Dynamic
receiveDyn = myProcess >>= liftIO . atomically . runReaderT receiveDynSTM

receiveAny :: (MonadProcess m, MonadIO m) => [Handle m] -> m ()
receiveAny hs = myProcess >>= liftIO . atomically . go [] >>= id
  where
    go xs me = do
        x <- runReaderT receiveDynSTM me
        hndlr <- hnd hs x
        case hndlr of
            Just h  -> requeue xs me >> return h
            Nothing -> go (x : xs) me
    hnd [] _ = return Nothing
    hnd (Case h : ys) x =
        case fromDynamic x of
            Nothing -> hnd ys x
            Just m  -> return $ Just (h m)
    hnd (Filter f h : ys) x =
        case fromDynamic x of
            Nothing -> hnd ys x
            Just  m ->
                if f m
                then return $ Just (h m)
                else hnd hs x
    hnd (Default m : _) _ = return $ Just m
        

requeue :: [Dynamic] -> Process -> STM ()
requeue xs = forM_ xs . unGetTQueue . mailbox

receiveMatch
    :: (MonadIO m, MonadProcess m, Typeable msg)
    => (msg -> Bool)
    -> m msg
receiveMatch f = myProcess >>= liftIO . atomically . go []
  where
    go xs me = do
        x <- runReaderT receiveDynSTM me
        case fromDynamic x of
            Nothing -> go (x : xs) me
            Just m  ->
                if f m
                then requeue xs me >> return m
                else go (x : xs) me

receive :: (MonadIO m, MonadProcess m, Typeable msg) => m msg
receive = receiveMatch (const True)

stop :: MonadIO m => Process -> m ()
stop proc = send proc Stop >> waitFor proc

kill :: MonadIO m => Process -> SomeException -> m ()
kill proc ex = send proc (Kill ex) >> waitFor proc

getProcessSTM :: String -> Process -> STM (Maybe Process)
getProcessSTM n p = do
    ps <- (p :) <$> readTVar (procs p)
    return $ find ((== Just n) . name) ps

getProcess :: String -> ProcessM Process
getProcess n = do
    me <- myProcess
    mproc <- liftIO . atomically $ getProcessSTM n me
    case mproc of
        Nothing -> liftIO . throwIO $ DependencyNotFound n
        Just proc -> return proc

myProcess :: MonadProcess m => m Process
myProcess = ask
