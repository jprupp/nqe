{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RecordWildCards           #-}
{-# OPTIONS_GHC -fno-full-laziness #-}
module Control.Concurrent.NQE.Process where

import           Control.Concurrent     (ThreadId, forkFinally, myThreadId)
import           Control.Concurrent.STM (STM, TMVar, TQueue, TVar, atomically,
                                         check, isEmptyTMVar, modifyTVar,
                                         newEmptyTMVar, newEmptyTMVarIO,
                                         newTQueue, newTVar, newTVarIO,
                                         putTMVar, readTMVar, readTMVar,
                                         readTQueue, readTVar, readTVarIO,
                                         throwSTM, unGetTQueue, writeTQueue,
                                         writeTVar)
import           Control.Exception      (Exception, SomeException, bracket,
                                         throwIO)
import           Control.Monad          (filterM, forM, when, (<=<))
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Data.Dynamic           (Dynamic, Typeable, fromDynamic, toDyn)
import           Data.List              (nub)
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (catMaybes, listToMaybe)
import           System.IO.Unsafe       (unsafePerformIO)

type Mailbox = TQueue (Either Signal Dynamic)
type ProcessMap = Map ThreadId Process

data Handle m
    = forall a. Typeable a =>
      HandleMatch
      { getHandle :: a -> m ()
      , getMatch  :: a -> Bool
      }
    | forall a. Typeable a =>
      Handle
      { getHandle :: a -> m () }
    | HandleSig
      { getSignal :: Signal -> m () }
    | HandleDefault
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
    = ProcessNotFound { notFound :: ThreadId }
    | CouldNotCastDynamic
    deriving (Show, Typeable)

instance Exception ProcessException

{-# NOINLINE processMap #-}
processMap :: TVar ProcessMap
processMap = unsafePerformIO $ newTVarIO Map.empty

-- | Start a new process running passed action.
startProcess :: IO ()   -- ^ action
             -> IO Process
startProcess action = do
    pbox <- newEmptyTMVarIO
    forkFinally (go pbox) (cleanup pbox)
    atomically $ readTMVar pbox
  where
    go pbox = do
        tid <- myThreadId
        atomically $ do
            p <- newProcessSTM tid
            putTMVar pbox p
        action
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

asProcess :: IO a    -- ^ action to run in a process context
          -> IO a
asProcess go =
    bracket acquire release $ const go
  where
    acquire = myThreadId >>= atomically . newProcessSTM
    release me = atomically $ cleanupSTM me $ Right ()

-- | Run another process while performing an action. Stop it when action
-- completes.
withProcess :: IO ()              -- ^ action on new process
            -> (Process -> IO a)  -- ^ action on current process
            -> IO a
withProcess f go =
    bracket acquire release go
  where
    acquire = startProcess f
    release = atomically . sendSTM Stop

isRunningSTM :: Process -> STM Bool
isRunningSTM Process{..} = isEmptyTMVar status

isRunning :: Process -> IO Bool
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
link :: Process   -- ^ master (kills this process before dying)
     -> IO ()
link remote = do
    me <- myProcess
    atomically $ linkSTM me remote

unLink :: Process -> IO ()
unLink Process{..} = myProcess >>= \me ->
    atomically $ modifyTVar links $ filter (/= me)

send :: Typeable msg => msg -> Process -> IO ()
send msg = atomically . sendSTM msg

sendSTM :: Typeable msg => msg -> Process -> STM ()
sendSTM msg = sendMsgSTM (Right $ toDyn msg)

sendMsg :: Either Signal Dynamic -> Process -> IO ()
sendMsg msg = atomically . sendMsgSTM msg

sendMsgSTM :: Either Signal Dynamic -> Process -> STM ()
sendMsgSTM msg Process{..} = writeTQueue mailbox msg

waitForSTM :: Process -> STM ()
waitForSTM = check . not <=< isRunningSTM

waitFor :: Process -> IO ()
waitFor = atomically . waitForSTM

receiveMsgSTM :: Process -> STM (Either Signal Dynamic)
receiveMsgSTM = readTQueue . mailbox

receiveMsg :: IO (Either Signal Dynamic)
receiveMsg = myProcess >>= atomically . receiveMsgSTM

requeue :: [Either Signal Dynamic] -> Process -> STM ()
requeue xs Process{..} = mapM_ (unGetTQueue mailbox) xs

handle :: MonadIO m => [Handle m] -> m ()
handle hs = do
    me <- liftIO myProcess
    action <- liftIO . atomically $ go me []
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
    handle (Right msg) (HandleMatch f t) =
        case fromDynamic msg of
            Nothing -> Nothing
            Just m -> if t m
                      then Just $ f m
                      else Nothing
    handle (Right msg) (Handle f) =
        case fromDynamic msg of
            Nothing -> Nothing
            Just m  -> Just $ f m
    handle (Right msg) (HandleDefault f) =
        Just $ f msg
    handle (Left s) (HandleSig f) =
        Just $ f s
    handle (Left s) _ =
        Nothing

receiveDynMatch :: (Dynamic -> Bool) -> IO Dynamic
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

receiveDyn :: IO Dynamic
receiveDyn = receiveDynMatch $ const True

receiveMatch :: Typeable msg => (msg -> Bool) -> IO msg
receiveMatch f = do
    d <- receiveDynMatch g
    case fromDynamic d of
        Just x  -> return x
        Nothing -> undefined
  where
    g d = case fromDynamic d of
        Just x  -> f x
        Nothing -> False

receive :: Typeable msg => IO msg
receive = receiveMatch (const True)

stop :: Process -> IO ()
stop = sendMsg $ Left Stop

myProcess :: IO Process
myProcess = do
    tid <- myThreadId
    threadProcess tid

threadProcessSTM :: ThreadId -> STM Process
threadProcessSTM tid = do
    pmap <- readTVar processMap
    case Map.lookup tid pmap of
        Nothing -> throwSTM $ ProcessNotFound tid
        Just p  -> return p

threadProcess :: ThreadId -> IO Process
threadProcess tid = do
    pmap <- readTVarIO processMap
    case Map.lookup tid pmap of
        Nothing -> throwIO $ ProcessNotFound tid
        Just p  -> return p

query :: (Typeable a, Typeable b) => a -> Process -> IO b
query q remote = do
    me <- myProcess
    send (me, q) remote
    snd <$> receiveMatch ((== remote) . fst)

getRequest :: Typeable a
           => IO (Process, a)
getRequest = receive

sendResponse :: Typeable a => a -> Process -> IO ()
sendResponse x p = do
    me <- myProcess
    send (me, x) p

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

getProcessErrorSTM :: Process -> STM (Maybe SomeException)
getProcessErrorSTM p@Process{..} = do
    r <- isRunningSTM p
    if r
        then return Nothing
        else do
        s <- readTMVar status
        case s of
            Left e  -> return $ Just e
            Right _ -> return Nothing

getProcessError :: Process
                -> IO (Maybe SomeException)
getProcessError = atomically . getProcessErrorSTM
