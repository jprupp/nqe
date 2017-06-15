{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE RecordWildCards           #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent     (ThreadId, forkFinally, myThreadId)
import           Control.Concurrent.STM (STM, TQueue, TVar, atomically, check,
                                         isEmptyTMVar, modifyTVar,
                                         newEmptyTMVar, newEmptyTMVarIO,
                                         newTQueue, newTVar, newTVarIO,
                                         putTMVar, readTMVar, readTQueue,
                                         readTVar, readTVarIO, throwSTM,
                                         unGetTQueue, writeTQueue, writeTVar)
import           Control.Exception      (Exception, SomeException, bracket,
                                         throwIO)
import           Control.Monad          (filterM, forM, when)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Reader   ()
import           Data.Dynamic           (Dynamic, Typeable, fromDynamic, toDyn)
import           Data.List              (nub)
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           System.IO.Unsafe       (unsafePerformIO)

type Mailbox = TQueue Dynamic
type ProcessMap = Map ThreadId Process

data Handle m = forall a. Typeable a =>
                Case { unHandle :: a -> m () }
              | forall a. Typeable a =>
                Filter { unFilter :: a -> Bool
                       , unHandle :: a -> m ()
                       }
              | Default { defHandle :: m () }

{-# NOINLINE processMap #-}
processMap :: TVar ProcessMap
processMap = unsafePerformIO $ newTVarIO Map.empty

data ProcessSpec = ProcessSpec
    { provides :: String
    , depends  :: [String]
    , action   :: IO ()
    } deriving (Typeable)

data Process = Process
    { name     :: String
    , thread   :: ThreadId
    , mailbox  :: Mailbox
    , procs    :: TVar [Process]
    , links    :: TVar [Process]
    , monitors :: TVar [Process]
    , running  :: TVar (Bool, Maybe SomeException)
    } deriving Typeable

instance Eq Process where
    a == b = thread a == thread b

data Signal
    = Stop
    | Linked { getLinked :: Remote }
    | Kill { killReason :: SomeException }
    deriving (Show, Typeable)

instance Exception Signal

data Remote
    = Finished { remoteName   :: String
               , remoteThread :: ThreadId
               }
    | Died { remoteName   :: String
           , remoteThread :: ThreadId
           , remoteError  :: SomeException
           }
    deriving (Show, Typeable)

data ProcessException
    = DependencyNotFound String
    | DependencyNotRunning String
    | ProcessNotFound ThreadId
    deriving (Eq, Show, Typeable)

instance Exception ProcessException

startProcess :: ProcessSpec -> IO Process
startProcess s = do
    parent <- myProcess
    tbox <- newEmptyTMVarIO
    tid <- forkFinally (go tbox parent) (cleanup tbox parent)
    atomically $ putTMVar tbox tid >> new tid parent
  where
    new thread parent@Process{procs = parentProcs} = do
        let name = provides s
        mailbox <- newTQueue
        running <- newTVar (True, Nothing)
        monitors <- newTVar []
        links <- newTVar []
        deps <- fmap concat $ forM (nub $ depends s) $ \dep -> do
            ds <- getProcessSTM dep parent
            when (null ds) $ throwSTM $ DependencyNotFound dep
            ds' <- filterM isRunningSTM ds
            when (null ds') $ throwSTM $ DependencyNotRunning dep
            return ds'
        procs <- newTVar deps
        let process = Process{..}
        mapM_ (linkSTM process) deps
        modifyTVar parentProcs (process:)
        modifyTVar processMap $ Map.insert thread process
        return process
    go tbox parent = do
        atomically $ isEmptyTMVar tbox >>= check . not
        action s
    cleanup tbox parent es = atomically $ do
        tid <- readTMVar tbox
        process <- threadProcessSTM tid
        ls <- readTVar (links process)
        ms <- readTVar (monitors process)
        let rmt = case es of
                Right _ -> Finished (name process) (thread process)
                Left e  -> Died (name process) (thread process) e
        mapM_ (sendSTM (Linked rmt)) ls
        mapM_ (sendSTM rmt) ms
        modifyTVar (procs parent) $ filter (/= process)
        writeTVar (running process) (False, either Just (const Nothing) es)
        modifyTVar processMap $ Map.delete tid

withProcess :: ProcessSpec
            -> (Process -> IO a)
            -> IO a
withProcess spec f = do
    me <- myProcess
    bracket (startProcess spec) stop f

-- | Add process context to current thread. Does not instantiate a new process.
initProcess :: MonadIO m
            => String   -- ^ name for process
            -> m ()
initProcess name = do
    thread <- liftIO myThreadId
    liftIO $ atomically $ do
        mailbox <- newTQueue
        procs <- newTVar []
        links <- newTVar []
        monitors <- newTVar []
        running <- newTVar (True, Nothing)
        modifyTVar processMap $ Map.insert thread Process{..}

isRunningSTM :: Process -> STM Bool
isRunningSTM Process{..} = fst <$> readTVar running

isRunning :: MonadIO m => Process -> m Bool
isRunning = liftIO . atomically . isRunningSTM

linkOrMonitorSTM :: Bool     -- ^ link
                 -> Process  -- ^ slave (receives signal if master dies)
                 -> Process  -- ^ master (sends signal to slave when it dies)
                 -> STM ()
linkOrMonitorSTM ln me remote = isRunningSTM remote >>= \r ->
    if r
    then add
    else dead >>= \sig ->
        if ln
        then sendSTM (Linked sig) me
        else sendSTM sig me
  where
    add = modifyTVar field $ (me:) . filter (/= me)
    field = if ln then links remote else monitors remote
    dead = do
        merr <- snd <$> readTVar (running remote)
        return $ case merr of
            Nothing -> Finished
                { remoteName = name remote
                , remoteThread = thread remote
                }
            Just e -> Died
                { remoteName = name remote
                , remoteThread = thread remote
                , remoteError = e
                }

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
waitForSTM Process{..} = readTVar running >>= check . not . fst

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
receiveMatch f = myProcess >>= liftIO . atomically . go []
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
stop remote = send Stop remote >> waitFor remote

kill :: MonadIO m => Process -> SomeException -> m ()
kill remote ex = send (Kill ex) remote >> waitFor remote

getProcessSTM :: String -> Process -> STM [Process]
getProcessSTM n p = do
    ps <- (p:) <$> readTVar (procs p)
    return $ filter ((==n) . name) ps

getProcess :: MonadIO m => String -> m [Process]
getProcess n = do
    me <- myProcess
    liftIO . atomically $ getProcessSTM n me

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
