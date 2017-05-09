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
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import System.IO.Unsafe

type Mailbox = TQueue Dynamic
type ProcessT = ReaderT Process
type ProcessM = ProcessT IO
type MonadProcess = MonadReader Process
type ProcessRegistry = Map String Process
type ReverseRegistry = Map ThreadId String

data Handle m   
    = forall a. Typeable a =>
        Case { unHandle :: a -> m () }
    | forall a. Typeable a =>
        Filter { unFilter :: a -> Bool
               , unHandle :: a -> m ()
               }
    |   Default { handleDef :: m () }

data Process
    = Process
        { thread   :: ThreadId
        , mailbox  :: Mailbox
        , links    :: TVar [Process]
        , monitors :: TVar [Process]
        , result   :: TMVar (Either SomeException Dynamic)
        }
    deriving Typeable

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
    | ProcessAlreadyRegisteredAs String
    | NameAlreadyRegistered String
    deriving (Show, Typeable)
instance Exception ProcessException

processRegistry :: TVar ProcessRegistry
processRegistry = unsafePerformIO $ newTVarIO Map.empty

reverseRegistry :: TVar ReverseRegistry
reverseRegistry = unsafePerformIO $ newTVarIO Map.empty

receiveDynSTM :: ProcessT STM Dynamic
receiveDynSTM = ask >>= \my -> lift $ do
    msg <- readTQueue $ mailbox my
    case fromDynamic msg of
        Just Stop       -> throwSTM Stopped
        Just (Linked l) -> throwSTM l
        Just (Kill s)   -> throwSTM s
        Nothing         -> return msg

startProcess :: Typeable a => Maybe String -> ProcessM a -> IO Process
startProcess mname action = do
    pbox <- atomically $ newEmptyTMVar
    tid <- forkFinally (go pbox) (cleanup pbox)
    atomically $ do
        p <- new tid
        putTMVar pbox p
        return p
  where
    new tid = do
        mbox <- newTQueue
        r <- newEmptyTMVar
        ls <- newTVar []
        ms <- newTVar []
        let p = Process { thread   = tid
                        , mailbox  = mbox
                        , links    = ls
                        , monitors = ms
                        , result   = r
                        }
        case mname of
            Just name -> registerSTM name p
            Nothing -> return ()
        return p
    go pbox = do
        p <- atomically $ do
            readTMVar pbox
        runReaderT action p
    cleanup pbox es = atomically $ do
        p@Process
            { links = lbox
            , monitors = mbox
            , result = rbox
            } <- readTMVar pbox
        ls <- readTVar lbox
        ms <- readTVar mbox
        let rm = case es of
                Right _ -> Finished (thread p)
                Left  e -> Died (thread p) e
        forM_ ls $ flip sendSTM $ Linked rm
        forM_ ms $ flip sendSTM rm
        deregisterSTM p
        putTMVar rbox $ toDyn <$> es

withProcess :: Typeable a
            => Maybe String
            -> ProcessM a
            -> (Process -> IO b)
            -> IO b
withProcess mname action = bracket (startProcess mname action) stop

isRunningSTM :: Process -> STM Bool
isRunningSTM Process{ result = rbox }= isEmptyTMVar rbox

isRunning :: MonadIO m => Process -> m Bool
isRunning = liftIO . atomically . isRunningSTM

link :: (MonadIO m, MonadProcess m) => Process -> m ()
link proc = do
    my <- ask
    liftIO . atomically $ do
        r <- isRunningSTM proc
        if r then add my else dead my
  where
    add my = modifyTVar (links proc) $
        (my:) . filter (remove my)
    remove my p = thread my /= thread p
    dead my = do
        se <- readTMVar (result proc)
        sendSTM my $ case se of
            Right _ -> Linked Finished
                { remoteThread = thread proc }
            Left  e -> Linked Died
                { remoteThread = thread proc
                , remoteError  = e
                }

unLink :: (MonadIO m, MonadProcess m) => Process -> m ()
unLink proc = do
    my <- ask
    liftIO . atomically $
        modifyTVar (links proc) $ filter (remove my)
  where
    remove my p = thread my /= thread p

monitor :: (MonadIO m, MonadProcess m) => Process -> m ()
monitor proc = do
    my <- ask
    liftIO . atomically $ do
        r <- isRunningSTM proc
        if r then add my else dead my
  where
    add my = modifyTVar (monitors proc) $
        (my:) . filter (remove my)
    remove my p = thread my /= thread p
    dead my = do
        es <- readTMVar (result proc)
        sendSTM my $ case es of
            Right _ -> Finished
                { remoteThread = thread proc }
            Left  e -> Died
                { remoteThread = thread proc
                , remoteError  = e
                }

deMonitor :: (MonadIO m, MonadProcess m) => Process -> m ()
deMonitor proc = do
    my <- ask
    liftIO . atomically $
        modifyTVar (monitors proc) $ filter (remove my)
  where
    remove my p = thread my /= thread p

send :: (MonadIO m, Typeable msg) => Process -> msg -> m ()
send proc = liftIO . atomically . sendSTM proc

sendSTM :: Typeable msg => Process -> msg -> STM ()
sendSTM proc = writeTQueue (mailbox proc) . toDyn

waitForSTM :: Process -> STM (Either SomeException Dynamic)
waitForSTM = readTMVar . result

waitFor :: MonadIO m => Process -> m (Either SomeException Dynamic)
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

receiveMatch :: (MonadIO m, MonadProcess m, Typeable msg)
             => (msg -> Bool)
             -> m msg
receiveMatch f = ask >>= liftIO . atomically . go []
  where
    go xs my = do
        x <- runReaderT receiveDynSTM my
        case fromDynamic x of
            Nothing -> go (x:xs) my
            Just m  -> if f m then requeue xs my >> return m else go (x:xs) my

receive :: (MonadIO m, MonadProcess m, Typeable msg) => m msg
receive = receiveMatch (const True)

stop :: MonadIO m => Process -> m (Either SomeException Dynamic)
stop proc = send proc Stop >> waitFor proc

kill :: MonadIO m
     => Process
     -> SomeException
     -> m (Either SomeException Dynamic)
kill proc ex = send proc (Kill ex) >> waitFor proc

registeredSTM :: ThreadId -> STM (Maybe String)
registeredSTM tid = Map.lookup tid <$> readTVar reverseRegistry

registered :: MonadIO m => Process -> m (Maybe String)
registered Process{ thread = tid } = liftIO . atomically $ registeredSTM tid

registerSTM :: String -> Process -> STM ()
registerSTM name proc@Process{ thread = tid } = do
    mn <- Map.lookup tid <$> readTVar reverseRegistry
    case mn of
        Just  n -> throwSTM $ ProcessAlreadyRegisteredAs n
        Nothing -> return ()
    mp <- Map.lookup name <$> readTVar processRegistry
    case mp of
        Just  _ -> throwSTM $ NameAlreadyRegistered name
        Nothing -> return ()
    modifyTVar processRegistry $ Map.insert name proc
    modifyTVar reverseRegistry $ Map.insert tid name

register :: MonadIO m => String -> Process -> m ()
register name proc = liftIO . atomically $ registerSTM name proc

deregisterSTM :: Process -> STM ()
deregisterSTM Process{ thread = tid } = do
    mn <- Map.lookup tid <$> readTVar reverseRegistry
    case mn of
        Just n -> do
            modifyTVar processRegistry $ Map.delete n
            modifyTVar reverseRegistry $ Map.delete tid
        Nothing -> return ()

deregister :: MonadIO m => Process -> m ()
deregister = liftIO . atomically . deregisterSTM

getRegisteredSTM :: String -> STM (Maybe Process)
getRegisteredSTM name = Map.lookup name <$> readTVar processRegistry

getRegistered :: MonadIO m => String -> m (Maybe Process)
getRegistered = liftIO . atomically . getRegisteredSTM

getProcess :: MonadIO m => String -> m Process
getProcess name = liftIO . atomically $ do
    mp <- getRegisteredSTM name
    case mp of
        Nothing -> retry
        Just  p -> return p

myProcess :: MonadProcess m => m Process
myProcess = ask
