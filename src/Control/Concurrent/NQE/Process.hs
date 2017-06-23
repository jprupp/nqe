{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RecordWildCards           #-}
{-# OPTIONS_GHC -fno-full-laziness #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent.Lifted   (ThreadId, forkFinally, myThreadId)
import           Control.Concurrent.STM      (STM, TMVar, TQueue, TVar, check,
                                              isEmptyTMVar, modifyTVar,
                                              newEmptyTMVar, newTQueue, newTVar,
                                              putTMVar, readTMVar, readTMVar,
                                              readTQueue, readTVar, throwSTM,
                                              unGetTQueue, writeTQueue,
                                              writeTVar)
import qualified Control.Concurrent.STM      as STM
import           Control.Exception.Lifted    (Exception, SomeException, bracket,
                                              throwIO)
import           Control.Monad               (filterM, forM, when, (<=<))
import           Control.Monad.Base          (MonadBase)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Control.Monad.Trans.Control (MonadBaseControl)
import           Data.Dynamic                (Dynamic, Typeable, fromDynamic,
                                              toDyn)
import           Data.List                   (nub)
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (catMaybes, listToMaybe)
import           System.IO.Unsafe            (unsafePerformIO)

type Mailbox = TQueue (Either Signal Dynamic)
type ProcessMap = Map ThreadId Process

data Handle m
    = forall a. Typeable a =>
      Case
      { getHandle :: a -> m () }
    | forall a. Typeable a =>
      Match
      { getHandle :: a -> m ()
      , getMatch  :: a -> Bool
      }
    | Sig
      { getSignal :: Signal -> m () }
    | Default
      { getDefault :: Dynamic -> m () }

data Process = Process
    { thread  :: ThreadId
    , mailbox :: Mailbox
    , links   :: TVar [Process]
    , status  :: TMVar (Either SomeException ())
    } deriving Typeable

instance Eq Process where
    a == b = thread a == thread b

instance Show Process where
    showsPrec d Process{..} =
        showParen (d > 10) $
        showString "Process { thread = " .
        shows thread .
        showString " }"

data Signal = Stop
            | Died { getThread :: ThreadId }
            deriving (Show, Eq, Typeable)

instance Exception Signal

data ProcessException
    = CouldNotCastDynamic
    deriving (Show, Typeable)

instance Exception ProcessException

{-# NOINLINE processMap #-}
processMap :: TVar ProcessMap
processMap = unsafePerformIO $ newTVarIO Map.empty

-- | Start a new process running passed action.
startProcess :: (MonadBaseControl IO m, MonadIO m)
             => m ()   -- ^ action
             -> m Process
startProcess action = do
    pbox <- newEmptyTMVarIO
    tid <- forkFinally (go pbox) (cleanup pbox)
    atomically $ do
        p <- newProcessSTM tid
        putTMVar pbox p
        return p
  where
    go pbox = atomically (readTMVar pbox) >> action
    cleanup pbox e = atomically $ do
        p <- readTMVar pbox
        cleanupSTM p e

newProcessSTM :: ThreadId
              -> STM Process
newProcessSTM thread = do
    mailbox <- newTQueue
    status <- newEmptyTMVar
    links <- newTVar []
    let process = Process{..}
    modifyTVar processMap $ Map.insert thread process
    return process

cleanupSTM :: Process
           -> Either SomeException ()
           -> STM ()
cleanupSTM p@Process{..} ret = do
    readTVar links >>= mapM_ (sendMsgSTM $ Left $ Died thread)
    putTMVar status ret
    modifyTVar processMap $ Map.delete thread

-- | Run another process while performing an action. Stop it when action
-- completes.
withProcess :: (MonadBaseControl IO m, MonadIO m)
            => m ()              -- ^ action on new process
            -> (Process -> m a)  -- ^ action on current process
            -> m a
withProcess f go =
    bracket acquire release go
  where
    acquire = startProcess f
    release p = do
        atomically $ stopSTM p
        waitFor p

isRunningSTM :: Process -> STM Bool
isRunningSTM Process{..} = isEmptyTMVar status

isRunning :: MonadIO m => Process -> m Bool
isRunning = atomically . isRunningSTM

linkSTM :: Process  -- ^ slave (receives signal if master dies)
        -> Process  -- ^ master (sends signal to slave when it dies)
        -> STM ()
linkSTM me remote = do
    r <- isRunningSTM remote
    if r then add else dead
  where
    add = modifyTVar (links remote) $ (me :) . filter (/= me)
    dead = sendMsgSTM (Left $ Died $ thread remote) me

-- | Make this process a slave of a remote process.
link :: (MonadBase IO m, MonadIO m)
     => Process   -- ^ master (kills this process before dying)
     -> m ()
link remote = do
    me <- myProcess
    atomically $ linkSTM me remote

unLink :: (MonadBase IO m, MonadIO m)
       => Process
       -> m ()
unLink Process{..} = myProcess >>= \me ->
    atomically $ modifyTVar links $ filter (/= me)

send :: (MonadIO m, Typeable msg) => msg -> Process -> m ()
send msg = atomically . sendSTM msg

sendSTM :: Typeable msg => msg -> Process -> STM ()
sendSTM msg = sendMsgSTM (Right $ toDyn msg)

sendMsg :: MonadIO m => Either Signal Dynamic -> Process -> m ()
sendMsg msg = atomically . sendMsgSTM msg

sendMsgSTM :: Either Signal Dynamic -> Process -> STM ()
sendMsgSTM msg Process{..} = writeTQueue mailbox msg

waitForSTM :: Process -> STM ()
waitForSTM = check . not <=< isRunningSTM

waitFor :: MonadIO m => Process -> m ()
waitFor = atomically . waitForSTM

receiveMsgSTM :: Process -> STM (Either Signal Dynamic)
receiveMsgSTM = readTQueue . mailbox

receiveMsg :: (MonadBase IO m, MonadIO m)
           => m (Either Signal Dynamic)
receiveMsg = myProcess >>= atomically . receiveMsgSTM

requeue :: [Either Signal Dynamic] -> Process -> STM ()
requeue xs Process{..} = mapM_ (unGetTQueue mailbox) xs

handle :: (MonadBase IO m, MonadIO m)
       => [Handle m]
       -> m ()
handle hs = do
    me <- myProcess
    action <- atomically $ go me []
    action
  where
    go me acc = do
        msgE <- receiveMsgSTM me
        case actionM msgE of
            Just action -> requeue acc me >> return action
            Nothing ->
                case msgE of
                    Left e  -> return $ liftIO $ throwIO e
                    Right _ -> go me (msgE : acc)
    actionM msgE = listToMaybe $ catMaybes $ map (handle msgE) hs
    handle (Right msg) (Match f t) =
        case fromDynamic msg of
            Nothing -> Nothing
            Just m -> if t m
                      then Just $ f m
                      else Nothing
    handle (Right msg) (Case f) =
        case fromDynamic msg of
            Nothing -> Nothing
            Just m  -> Just $ f m
    handle (Right msg) (Default f) =
        Just $ f msg
    handle (Left s) (Sig f) =
        Just $ f s
    handle (Left s) _ =
        Nothing

receiveDynMatch :: (MonadBase IO m, MonadIO m)
                => (Dynamic -> Bool)
                -> m Dynamic
receiveDynMatch f = do
    me <- myProcess
    atomically $ go [] me
  where
    go xs me = do
        xE <- receiveMsgSTM me
        case xE of
            Left e  -> throwSTM e
            Right x -> g xs me x
    g xs me x =
        if f x
        then requeue xs me >> return x
        else go (Right x : xs) me

receiveDyn :: (MonadBase IO m, MonadIO m)
           => m Dynamic
receiveDyn = receiveDynMatch $ const True

receiveMatch :: (MonadBase IO m, MonadIO m, Typeable msg)
             => (msg -> Bool)
             -> m msg
receiveMatch f = do
    d <- receiveDynMatch g
    case fromDynamic d of
        Just x  -> return x
        Nothing -> undefined
  where
    g d = case fromDynamic d of
        Just x  -> f x
        Nothing -> False

receive :: (MonadBase IO m, MonadIO m, Typeable msg)
        => m msg
receive = receiveMatch (const True)

stopSTM :: Process -> STM ()
stopSTM = sendMsgSTM $ Left Stop

stop :: MonadIO m => Process -> m ()
stop = atomically . stopSTM

myProcess :: (MonadBase IO m, MonadIO m) => m Process
myProcess = do
    tid <- myThreadId
    threadProcess tid

threadProcessSTM :: ThreadId -> STM Process
threadProcessSTM tid = do
    pmap <- readTVar processMap
    case Map.lookup tid pmap of
        Nothing -> newProcessSTM tid
        Just p  -> return p

threadProcess :: (MonadBase IO m, MonadIO m)
              => ThreadId
              -> m Process
threadProcess = atomically . threadProcessSTM

query :: (MonadBase IO m, MonadIO m)
      => (Typeable a, Typeable b)
      => a
      -> Process
      -> m b
query q remote = do
    me <- myProcess
    send (me, q) remote
    snd <$> receiveMatch ((== remote) . fst)

respond :: (MonadBase IO m, MonadIO m, Typeable a, Typeable b)
        => (a -> m b)
        -> m ()
respond f = do
    me <- myProcess
    (p, q) <- receive
    r <- f q
    send (me, r) p

didCleanExit :: Process -> STM Bool
didCleanExit p@Process{..} = do
    r <- isRunningSTM p
    if r
        then return False
        else do
        s <- readTMVar status
        case s of
            Right _ -> return True
            Left _  -> return False

getProcessErrorSTM :: Process
                   -> STM (Maybe SomeException)
getProcessErrorSTM p@Process{..} = do
    r <- isRunningSTM p
    if r
        then return Nothing
        else do
        s <- readTMVar status
        case s of
            Left e  -> return $ Just e
            Right _ -> return Nothing

getProcessError :: MonadIO m
                => Process
                -> m (Maybe SomeException)
getProcessError = atomically . getProcessErrorSTM


atomically :: MonadIO m => STM a -> m a
atomically = liftIO . STM.atomically

newEmptyTMVarIO :: MonadIO m => m (TMVar a)
newEmptyTMVarIO = liftIO STM.newEmptyTMVarIO

newTVarIO :: MonadIO m => a -> m (TVar a)
newTVarIO = liftIO . STM.newTVarIO

readTVarIO :: MonadIO m => TVar a -> m a
readTVarIO = liftIO . STM.readTVarIO
