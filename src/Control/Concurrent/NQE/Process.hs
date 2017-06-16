{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RecordWildCards           #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent          (ThreadId, forkFinally, myThreadId)
import           Control.Concurrent.STM      (STM, TQueue, TVar, atomically,
                                              check, isEmptyTMVar, modifyTVar,
                                              newEmptyTMVar, newEmptyTMVarIO,
                                              newTQueue, newTVar, newTVarIO,
                                              putTMVar, readTMVar, readTQueue,
                                              readTVar, readTVarIO, throwSTM,
                                              unGetTQueue, writeTQueue,
                                              writeTVar)
import           Control.Exception.Lifted    (Exception, SomeException, bracket,
                                              throwIO)
import           Control.Monad               (filterM, forM, when)
import           Control.Monad.Base          (MonadBase)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Control.Monad.Reader        ()
import           Control.Monad.Trans.Control (MonadBaseControl)
import           Data.Dynamic                (Dynamic, Typeable, fromDynamic,
                                              toDyn)
import           Data.List                   (nub)
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as Map
import           System.IO.Unsafe            (unsafePerformIO)

type Mailbox = TQueue Dynamic
type ProcessMap = Map ThreadId Process

data Handle m
    = forall a. Typeable a =>
      Case { unHandle :: a -> m () }
    | forall a. Typeable a =>
      Filter { unFilter :: a -> Bool
             , unHandle :: a -> m ()
             }
    | Default { defHandle :: m () }

{-# NOINLINE processMap #-}
processMap :: TVar ProcessMap
processMap = unsafePerformIO $ newTVarIO Map.empty

data ProcessStatus
    = StatusRunning
    | StatusStopped
    | StatusDead { statusException :: SomeException }
    deriving Show

data Process = Process
    { name     :: String
    , thread   :: ThreadId
    , mailbox  :: Mailbox
    , links    :: TVar [Process]
    , monitors :: TVar [Process]
    , status   :: TVar ProcessStatus
    } deriving Typeable

instance Eq Process where
    a == b = thread a == thread b

data Signal = Stop { byProcess :: ThreadId }
    deriving (Show, Typeable)

instance Exception Signal

data ProcessException
    = ProcessNotFound { notFound :: ThreadId }
    deriving (Show, Typeable)

instance Exception ProcessException

-- | Start a new process running passed action.
startProcess :: String  -- ^ name
             -> IO ()   -- ^ action
             -> IO Process
startProcess n action = do
    tbox <- newEmptyTMVarIO
    tid <- forkFinally (go tbox) (cleanup tbox)
    atomically $ putTMVar tbox tid >> newProcessSTM tid n
  where
    go tbox = do
        atomically $ isEmptyTMVar tbox >>= check . not
        action
    cleanup tbox e = atomically $ do
        tid <- readTMVar tbox
        cleanupSTM tid e

newProcessSTM :: ThreadId
              -> String    -- ^ name
              -> STM Process
newProcessSTM thread name = do
    mailbox <- newTQueue
    status <- newTVar StatusRunning
    monitors <- newTVar []
    links <- newTVar []
    modifyTVar processMap $ Map.insert thread Process{..}
    return Process{..}

cleanupSTM :: ThreadId -> Either SomeException a -> STM ()
cleanupSTM tid e = do
    Process{..} <- threadProcessSTM tid
    readTVar links >>= mapM_ (sendSTM (Stop thread))
    readTVar monitors >>= mapM_ (sendSTM thread)
    writeTVar status $ either StatusDead (const StatusStopped) e
    modifyTVar processMap $ Map.delete thread

-- | Run action in separate process. Simultaneously run another action in
-- current thread. When action in current thread finished, stop other process if
-- still running. Current thread will get a process data structure while action
-- runs. The name of current thread's process will be "main".
withProcess :: (MonadIO m, MonadBaseControl IO m)
            => String  -- ^ name for other process
            -> IO ()   -- ^ action
            -> (Process -> m a)
            -> m a
withProcess n f go =
    bracket acquire release go
  where
    acquire = liftIO $ do
        me <- myThreadId
        atomically $ newProcessSTM me "main"
        startProcess n f
    release p = liftIO $ do
        me <- myThreadId
        atomically $ do
            sendSTM (Stop me) p
            cleanupSTM me (Right ())

isRunningSTM :: Process -> STM Bool
isRunningSTM Process{..} = do
    s <- readTVar status
    case s of
        StatusRunning -> return True
        _ -> return False

isRunning :: MonadIO m => Process -> m Bool
isRunning = liftIO . atomically . isRunningSTM

linkOrMonitorSTM :: Bool     -- ^ link
                 -> Process  -- ^ slave (receives signal if master dies)
                 -> Process  -- ^ master (sends signal to slave when it dies)
                 -> STM ()
linkOrMonitorSTM ln me remote = do
    r <- isRunningSTM remote
    if r then add else dead
  where
    add = modifyTVar field $ (me :) . filter (/= me)
    field = if ln
            then links remote
            else monitors remote
    dead = if ln
           then sendSTM (Stop $ thread remote) me
           else sendSTM (thread remote) me

-- | Link processes such that the first one becomes a slave to the second.
linkSTM :: Process   -- ^ slave (dies with master)
        -> Process   -- ^ master (kills slave before dying)
        -> STM ()
linkSTM = linkOrMonitorSTM True

-- | Make this process a slave of a remote process.
link :: MonadIO m
     => Process   -- ^ master (kills this process before dying)
     -> m ()
link remote = myProcess >>= \me -> liftIO . atomically $ linkSTM me remote

unLink :: MonadIO m => Process -> m ()
unLink remote = do
    me <- myProcess
    liftIO . atomically $ modifyTVar (links remote) $ filter (/= me)

-- | Monitor a remote process.
monitorSTM :: Process  -- ^ process that receives monitoring information
           -> Process  -- ^ process to be monitored
           -> STM ()
monitorSTM = linkOrMonitorSTM False

-- | Get a signal when remote process dies.
monitor :: MonadIO m
        => Process   -- ^ if this dies the current process gets a signal
        -> m ()
monitor remote = myProcess >>= \me -> liftIO . atomically $ monitorSTM me remote

deMonitor :: MonadIO m => Process -> m ()
deMonitor remote = do
    me <- myProcess
    liftIO . atomically $ modifyTVar (monitors remote) $ filter (/= me)

send :: (MonadIO m, Typeable msg) => msg -> Process -> m ()
send msg = liftIO . atomically . sendSTM msg

sendSTM :: Typeable msg => msg -> Process -> STM ()
sendSTM msg remote = writeTQueue (mailbox remote) $ toDyn msg

waitForSTM :: Process -> STM ()
waitForSTM p = do
    r <- isRunningSTM p
    check $ not r

waitFor :: MonadIO m => Process -> m ()
waitFor = liftIO . atomically . waitForSTM

receiveDynSTM :: Process -> STM Dynamic
receiveDynSTM me = do
    msg <- readTQueue $ mailbox me
    case fromDynamic msg of
        Just sig -> throwSTM (sig :: Signal)
        Nothing  -> return msg

receiveDyn :: MonadIO m => m Dynamic
receiveDyn = myProcess >>= liftIO . atomically . receiveDynSTM

receiveAny :: MonadIO m => [Handle m] -> m ()
receiveAny hs = do
    me <- myProcess
    action <- liftIO . atomically $ go [] me
    action
  where
    go xs me = do
        x <- receiveDynSTM me
        actionM <- getAction hs x
        case actionM of
            Just action -> requeue xs me >> return action
            Nothing     -> go (x:xs) me
    getAction [] _ = return Nothing
    getAction (Case h : ys) x =
        case fromDynamic x of
            Nothing -> getAction ys x
            Just m  -> return $ Just (h m)
    getAction (Filter f h : ys) x =
        case fromDynamic x of
            Nothing -> getAction ys x
            Just m ->
                if f m
                then return $ Just (h m)
                else getAction ys x
    getAction (Default m : _) _ = return $ Just m


requeue :: [Dynamic] -> Process -> STM ()
requeue xs Process{..} = mapM_ (unGetTQueue mailbox) xs

receiveMatch :: (MonadIO m, Typeable msg)
             => (msg -> Bool)
             -> m msg
receiveMatch f = do
    me <- myProcess
    liftIO . atomically $ go [] me
  where
    go xs me = do
        x <- receiveDynSTM me
        case fromDynamic x of
            Nothing -> go (x:xs) me
            Just m  -> if f m
                       then requeue xs me >> return m
                       else go (x:xs) me

receive :: (MonadIO m, Typeable msg) => m msg
receive = receiveMatch (const True)

stop :: MonadIO m => Process -> m ()
stop remote = myProcess >>= \p -> send (Stop (thread p)) remote

myProcess :: MonadIO m => m Process
myProcess = do
    tid <- liftIO myThreadId
    threadProcess tid

threadProcessSTM :: ThreadId -> STM Process
threadProcessSTM tid = do
    pmap <- readTVar processMap
    case Map.lookup tid pmap of
        Nothing -> throwSTM $ ProcessNotFound tid
        Just p  -> return p

threadProcess :: MonadIO m => ThreadId -> m Process
threadProcess tid = do
    pmap <- liftIO $ readTVarIO processMap
    case Map.lookup tid pmap of
        Nothing -> liftIO . throwIO $ ProcessNotFound tid
        Just p  -> return p

query :: (MonadIO m, Typeable a, Typeable b)
      => a
      -> Process
      -> m b
query q remote = do
    me <- myProcess
    send (me, q) remote
    snd <$> receiveMatch ((== remote) . fst)

respond :: (MonadIO m, Typeable a, Typeable b)
        => (a -> m b)
        -> m ()
respond f = do
    (remote, q) <- receive
    res <- f q
    me <- myProcess
    send (me, res) remote
