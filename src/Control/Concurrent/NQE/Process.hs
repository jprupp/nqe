{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RecordWildCards           #-}
{-# OPTIONS_GHC -fno-full-laziness #-}
module Control.Concurrent.NQE.Process where

import           Control.Applicative         ((<|>))
import           Control.Concurrent.Lifted   (ThreadId, forkFinally, myThreadId,
                                              threadDelay)
import           Control.Concurrent.STM      (STM, TMVar, TQueue, TVar,
                                              atomically, check, isEmptyTMVar,
                                              isEmptyTQueue, modifyTVar,
                                              newEmptyTMVar, newEmptyTMVarIO,
                                              newTQueue, newTVar, newTVarIO,
                                              putTMVar, readTMVar, readTMVar,
                                              readTQueue, readTVar, unGetTQueue,
                                              writeTQueue)
import           Control.Exception.Lifted    (Exception, SomeException, bracket,
                                              fromException, throwTo)
import           Control.Monad               (forM_, join, void, (<=<))
import           Control.Monad.Base          (MonadBase)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Control.Monad.Trans.Control (MonadBaseControl)
import           Data.Dynamic                (Dynamic, Typeable, fromDynamic,
                                              toDyn)
import           Data.Function               (on)
import           Data.List                   (delete, nub)
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (isNothing)
import           System.IO.Unsafe            (unsafePerformIO)

type Mailbox = TQueue Dynamic
type ProcessMap = Map ThreadId Process

data Dispatch m
    = forall a b. (Typeable a, Typeable b) =>
      Query { answerIt :: !(a -> m b) }
    | forall a. Typeable a =>
      Case { getAction :: !(a -> m ()) }
    | forall a b. Typeable a =>
      Match { getAction :: !(b -> m ()), getMatch  :: !(a -> Maybe b) }
    | Default { getDefault :: !(Dynamic -> m ()) }

data Process = Process
    { thread   :: !ThreadId
    , mailbox  :: !Mailbox
    , children :: !(TVar [Process])
    , links    :: !(TVar [Process])
    , monitors :: !(TVar [Process])
    , status   :: !(TMVar (Maybe SomeException))
    } deriving Typeable

instance Eq Process where
    (==) = (==) `on` thread

instance Ord Process where
    compare = compare `on` thread

instance Show Process where
    showsPrec d Process{..} =
        showParen (d > 10) $ showString "Process " . shows thread

data Signal = Stop { signalProcess   :: !Process }
            | Died { signalProcess   :: !Process
                   , signalException :: !(Maybe SomeException)
                   }
            deriving (Show, Typeable)

instance Exception Signal

instance Eq Signal where
    Stop { signalProcess = p1 } == Stop { signalProcess = p2 } = p1 == p2
    Died { signalProcess = p1 } == Died { signalProcess = p2 } = p1 == p2
    _ == _ = False

data ProcessException
    = CouldNotCastDynamic
    | LinkedProcessDied !Process !SomeException
    deriving (Show, Typeable)

data QuietException
    = ParentEnded
    | WrappingActionEnded
    deriving (Show, Typeable)

instance Exception ProcessException
instance Exception QuietException

{-# NOINLINE processMap #-}
processMap :: TVar ProcessMap
processMap = unsafePerformIO $ liftIO $ newTVarIO Map.empty

-- | Start a new process running passed action.
startProcess :: (MonadBaseControl IO m, MonadIO m)
             => m ()   -- ^ action
             -> m Process
startProcess action = do
    me <- myProcess
    pbox <- liftIO newEmptyTMVarIO
    tid <- forkFinally (go pbox) (cleanup pbox me)
    atomicallyIO $ do
        p <- newProcessSTM tid (Just me)
        putTMVar pbox p
        return p
  where
    go pbox = atomicallyIO (readTMVar pbox) >> action
    cleanup pbox me e = do
        (p, cdn, lns) <-
            atomicallyIO $ do
                p <- readTMVar pbox
                (cdn, lns) <- cleanupSTM p me e
                return (p, cdn, lns)
        case e of
            Right () -> return ()
            Left ex ->
                case fromException ex of
                    Just ParentEnded -> return ()
                    Just _ -> return ()
                    Nothing -> mapM_ (LinkedProcessDied p ex `kill`) lns
        mapM_ (ParentEnded `kill`) cdn

newProcessSTM :: ThreadId
              -> Maybe Process   -- ^ parent
              -> STM Process
newProcessSTM tid parM = do
    mbox <- newTQueue
    stat <- newEmptyTMVar
    lns  <- newTVar []
    mons <- newTVar []
    cdn  <- newTVar []
    let p = Process{ thread = tid
                   , mailbox = mbox
                   , status = stat
                   , links = lns
                   , monitors = mons
                   , children = cdn
                   }
    modifyTVar processMap $ Map.insert tid p
    case parM of
        Just par -> modifyTVar (children par) $ nub . (p :)
        Nothing  -> return ()
    return p

cleanupSTM :: Process
           -> Process  -- ^ parent
           -> Either SomeException ()
           -> STM ([Process], [Process])
cleanupSTM p par ex = do
    let e = either Just (const Nothing) ex
    modifyTVar (children par) $ delete p . nub
    putTMVar (status p) e
    mns <- readTVar (monitors p)
    forM_ mns $ sendSTM $ Died p e
    modifyTVar processMap $ Map.delete (thread p)
    lns <- readTVar (links p)
    cdn <- readTVar (children p)
    return (cdn, lns)

-- | Run another process while performing an action. Stop it when action
-- completes.
withProcess :: (MonadBaseControl IO m, MonadIO m)
            => m ()              -- ^ action on new process
            -> (Process -> m a)  -- ^ action on current process
            -> m a
withProcess f go =
    bracket acquire release $ \p -> link p >> go p
  where
    acquire = startProcess f
    release p = do
        WrappingActionEnded `kill` p
        waitFor p

mailboxEmptySTM :: Process -> STM Bool
mailboxEmptySTM Process{..} = isEmptyTQueue mailbox

mailboxEmpty :: MonadIO m => Process -> m Bool
mailboxEmpty = atomicallyIO . mailboxEmptySTM

isRunningSTM :: Process -> STM Bool
isRunningSTM Process{..} = isEmptyTMVar status

isRunning :: MonadIO m => Process -> m Bool
isRunning = atomicallyIO . isRunningSTM

link :: (MonadIO m, MonadBase IO m) => Process -> m ()
link p = do
    me <- myProcess
    linkProcesses me p

linkProcesses :: (MonadIO m, MonadBase IO m)
              => Process  -- ^ this one gets killed
              -> Process  -- ^ if this one stops
              -> m ()
linkProcesses me remote = do
    err <-
        atomicallyIO $ do
            r <- isRunningSTM remote
            if r
                then add
                else dead
    case err of
        Nothing -> return ()
        Just ex ->
            case fromException ex of
                Just ParentEnded -> return ()
                Just _           -> return ()
                Nothing          -> LinkedProcessDied remote ex `kill` me
  where
    add = do
        modifyTVar (links remote) $ (me :) . filter (/= me)
        return Nothing
    dead = getExceptionSTM remote

monitorSTM :: Process  -- ^ monitoring
           -> Process  -- ^ monitored
           -> STM ()
monitorSTM me remote = do
    r <- isRunningSTM remote
    if r then add else dead
  where
    add = modifyTVar (monitors remote) $ (me :) . filter (/= me)
    dead = do
        ex <- getExceptionSTM remote
        Died remote ex `sendSTM` me

unlink :: (MonadBase IO m, MonadIO m)
       => Process
       -> m ()
unlink p = do
    me <- myProcess
    unlinkProcesses me p

unlinkProcesses :: (MonadIO m, MonadBase IO m)
                => Process
                -> Process
                -> m ()
unlinkProcesses me remote =
    atomicallyIO $ modifyTVar (links remote) $ filter (/= me)

-- | Monitor a process, getting a signal if it stops.
monitor :: (MonadBase IO m, MonadIO m)
        => Process
        -> m ()
monitor remote = do
    me <- myProcess
    atomicallyIO $ monitorSTM me remote

deMonitor :: (MonadBase IO m, MonadIO m)
          => Process
          -> m ()
deMonitor Process{..} = myProcess >>= \me ->
    atomicallyIO $ modifyTVar monitors $ filter (/= me)

asyncDelayed :: (MonadIO m, MonadBaseControl IO m)
             => Int
             -> m ()
             -> m ()
asyncDelayed t f = void $ do
    me <- myProcess
    void $ forkFinally delay $ \e ->
        case e of
            Left ex  -> ex `kill` me
            Right () -> return ()
  where
    delay = threadDelay (t * 1000 * 1000) >> f

sendSTM :: Typeable msg => msg -> Process -> STM ()
sendSTM msg Process{..} = writeTQueue mailbox $ toDyn msg

send :: (MonadIO m, Typeable msg) => msg -> Process -> m ()
send msg = atomicallyIO . sendSTM msg

stop :: (MonadIO m, MonadBase IO m) => Process -> m ()
stop p = do
    me <- myProcess
    Stop { signalProcess = me } `send` p

waitForSTM :: Process -> STM ()
waitForSTM = check . not <=< isRunningSTM

waitFor :: MonadIO m => Process -> m ()
waitFor = atomicallyIO . waitForSTM

requeue :: [Dynamic] -> Process -> STM ()
requeue xs Process{..} = mapM_ (unGetTQueue mailbox) xs

dispatch :: (MonadBase IO m, MonadIO m)
         => [Dispatch m]
         -> m ()
dispatch hs = do
    me <- myProcess
    join $ atomicallyIO $ go me []
  where
    go me@Process{..} acc = do
        dyn <- readTQueue mailbox
        case action dyn of
            Just act -> requeue acc me >> return act
            Nothing  -> go me (dyn : acc)
    action dyn = foldl (g dyn) Nothing hs
    g dyn acc x = acc <|> h dyn x
    h dyn x =
        case x of
            Match f t -> do
                m <- fromDynamic dyn
                case t m of
                    Just y -> Just $ f y
                    Nothing -> Nothing
            Case f ->
                f <$> fromDynamic dyn
            Query f -> do
                (p, q) <- fromDynamic dyn
                return $ do
                    r <- f q
                    me <- myProcess
                    send (me, r) p
            Default f ->
                return $ f dyn

receiveMatch :: (MonadIO m, MonadBase IO m, Typeable msg)
             => (msg -> Maybe a)
             -> m a
receiveMatch f = do
    me <- myProcess
    atomicallyIO $ go me []
  where
    go me acc = do
        dyn <- readTQueue (mailbox me)
        case fromDynamic dyn of
            Nothing -> go me (dyn : acc)
            Just x ->
                case f x of
                    Just y -> requeue acc me >> return y
                    Nothing -> go me (dyn : acc)

receive :: (MonadBase IO m, MonadIO m, Typeable msg) => m msg
receive = receiveMatch Just

kill :: (MonadIO m, MonadBase IO m, Exception e) => e -> Process -> m ()
kill e p = throwTo (thread p) e

myProcess :: (MonadBase IO m, MonadIO m) => m Process
myProcess = do
    tid <- myThreadId
    threadProcess tid

threadProcessSTM :: ThreadId -> STM Process
threadProcessSTM tid = do
    pmap <- readTVar processMap
    case Map.lookup tid pmap of
        Nothing -> newProcessSTM tid Nothing
        Just p  -> return p

threadProcess :: (MonadBase IO m, MonadIO m)
              => ThreadId
              -> m Process
threadProcess = atomicallyIO . threadProcessSTM

query :: (MonadBase IO m, MonadIO m)
      => (Typeable a, Typeable b)
      => a
      -> Process
      -> m b
query q remote = do
    me <- myProcess
    send (me, q) remote
    receiveMatch (\(x, y) -> if x == remote then Just y else Nothing)

respond :: (MonadBase IO m, MonadIO m, Typeable a, Typeable b)
        => (a -> m b)
        -> m ()
respond f = do
    me <- myProcess
    (p, q) <- receive
    r <- f q
    send (me, r) p

hasException :: Process -> STM Bool
hasException p@Process{..} = do
    r <- isRunningSTM p
    if r
        then return False
        else isNothing <$> readTMVar status

getExceptionSTM :: Process
                -> STM (Maybe SomeException)
getExceptionSTM p@Process{..} = do
    r <- isRunningSTM p
    if r
        then return Nothing
        else readTMVar status

getException :: MonadIO m
             => Process
             -> m (Maybe SomeException)
getException = atomicallyIO . getExceptionSTM

atomicallyIO :: MonadIO m => STM a -> m a
atomicallyIO = liftIO . atomically
