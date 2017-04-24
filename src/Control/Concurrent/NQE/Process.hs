module Control.Concurrent.NQE.Process
    ( Process
    , procThreadId
    , procName

    , Link(..)
    , ProcessException(..)

    , getProcess
    , getMyProcess

    , startProcess
    , withProcess

    , isRunning

    , link
    , unLink
    
    , monitor
    , deMonitor

    , send
    , receive
    , receiveAny
    , receiveMonitor
    , receiveMatch
    , receiveMonitorMatch

    , waitFor
    , stop
    , kill
    ) where

--
-- Non-blocking asynchronous processes with mailboxes
--

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Data.Dynamic
import Data.Maybe
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Typeable
import GHC.Conc
import System.IO.Unsafe

--
-- External data types
--

-- Do not expose constructor or extractors for Process

data Process = Process
    { procThreadId :: ThreadId
    , procName     :: String
    , procMailbox  :: TQueue Dynamic
    , procLinks    :: TVar (Set ThreadId)
    , procMonitors :: TVar (Set ThreadId)
    , procRunning  :: TVar (Bool, Maybe SomeException)
    } deriving (Typeable)

data ProcSig
    = SigStop
    | SigLink { sigLink  :: Link }
    | SigKill { sigError :: SomeException }
    deriving (Show, Typeable)

data Link
    = LinkFinished
        { linkThreadId   :: ThreadId
        , linkProcName   :: String
        }
    | LinkDied
        { linkThreadId   :: ThreadId
        , linkProcName   :: String
        , linkError      :: SomeException
        }
    deriving (Show, Typeable)
instance Exception Link

data ProcessException
    = NoProcessFor { errThreadId  :: ThreadId }
    | Stopped
    deriving (Show, Typeable)
instance Exception ProcessException

--
-- Internal data types
--

type ProcessTable = Map ThreadId Process

--
-- Internal functions
--

processTable :: TVar ProcessTable
processTable = unsafePerformIO $ newTVarIO Map.empty

getProcessSTM :: ThreadId -> STM (Maybe Process)
getProcessSTM tid = Map.lookup tid <$> readTVar processTable

receiveAnySTM :: Process -> STM Dynamic
receiveAnySTM my = do
    msg <- readTQueue (procMailbox my)
    case fromDynamic msg of
        Just SigStop     -> throw Stopped
        Just (SigLink l) -> throw l
        Just (SigKill s) -> throw s
        Nothing          -> return msg

--
-- External functions
--

getProcess :: ThreadId -> IO (Maybe Process)
getProcess = atomically . getProcessSTM

getMyProcess :: IO Process
getMyProcess = myThreadId >>= fmap fromJust . getProcess

startProcess
    :: String
    -> (Process -> IO ())
    -> IO Process
startProcess name action = do
    pv <- atomically $ newEmptyTMVar
    tid <- forkFinally (go pv) (cleanup pv)
    atomically $ do
        proc <- new tid
        putTMVar pv proc
        return proc
  where
    new tid = do
        pt <- readTVar processTable
        mbox <- newTQueue
        running <- newTVar (True, Nothing)
        ls <- newTVar $ Set.empty
        ms <- newTVar $ Set.empty
        let proc = Process tid name mbox ls ms running
        modifyTVar processTable $ Map.insert tid proc
        return proc
    go pv = do
        proc <- atomically $ readTMVar pv
        action proc
    cleanup pv es = atomically $ do
        proc <- readTMVar pv
        ls <- readTVar $ procLinks proc
        ms <- readTVar $ procMonitors proc
        lns <- fmap catMaybes $ mapM getProcessSTM $ Set.elems ls
        mns <- fmap catMaybes $ mapM getProcessSTM $ Set.elems ms 
        let em = either Just (const Nothing) es
        forM_ lns $ flip sendSTM $ case em of
            Nothing -> SigLink LinkFinished
                { linkThreadId = procThreadId proc
                , linkProcName = procName proc
                }
            Just e -> SigLink LinkDied
                { linkThreadId = procThreadId proc
                , linkProcName = procName proc
                , linkError    = e
                }
        forM_ mns $ flip sendSTM $ case em of
            Nothing -> LinkFinished
                { linkThreadId = procThreadId proc
                , linkProcName = procName proc
                }
            Just e -> LinkDied
                { linkThreadId = procThreadId proc
                , linkProcName = procName proc
                , linkError    = e
                }
        writeTVar (procRunning proc) (False, em)
        modifyTVar processTable $ Map.delete $ procThreadId proc

withProcess :: String -> (Process -> IO ()) -> (Process -> IO ()) -> IO ()
withProcess name action = bracket (startProcess name action) stop

isRunningSTM :: Process -> STM Bool
isRunningSTM = fmap fst . readTVar . procRunning

isRunning :: Process -> IO Bool
isRunning = atomically . isRunningSTM

link :: Process -> IO ()
link proc = do
    tid <- myThreadId
    atomically $ do
        my <- fromJust <$> getProcessSTM tid
        running <- isRunningSTM proc
        if running then add tid else dead my
  where
    add tid = modifyTVar (procLinks proc) $ Set.insert tid
    dead my = do
        em <- fmap snd $ readTVar $ procRunning proc
        sendSTM my $ case em of
            Nothing -> SigLink LinkFinished
                { linkThreadId = procThreadId proc
                , linkProcName = procName proc
                }
            Just e -> SigLink LinkDied
                { linkThreadId = procThreadId proc
                , linkProcName = procName proc
                , linkError    = e
                }

unLink :: Process -> IO ()
unLink proc = do
    my <- myThreadId
    atomically $ modifyTVar (procLinks proc) $ Set.delete my

monitor :: Process -> IO ()
monitor proc = do
    tid <- myThreadId
    atomically $ do
        my <- fromJust <$> getProcessSTM tid
        running <- isRunningSTM proc
        if running then add tid else dead my
  where
    add tid = modifyTVar (procMonitors proc) $ Set.insert tid
    dead my = do
        em <- fmap snd $ readTVar $ procRunning proc
        sendSTM my $ case em of
            Nothing -> LinkFinished
                { linkThreadId = procThreadId proc
                , linkProcName = procName proc
                }
            Just e -> LinkDied
                { linkThreadId = procThreadId proc
                , linkProcName = procName proc
                , linkError    = e
                }

deMonitor :: Process -> IO ()
deMonitor proc = do
    my <- myThreadId
    atomically $ modifyTVar (procMonitors proc) $ Set.delete my

send :: Typeable a => Process -> a -> IO ()
send proc = atomically . sendSTM proc

sendSTM :: Typeable a => Process -> a -> STM ()
sendSTM proc = writeTQueue (procMailbox proc) . toDyn

waitFor :: Process -> IO ()
waitFor proc = atomically $ do
    (running, em) <- readTVar $ procRunning proc
    check $ not running
    case em of
        Nothing -> return ()
        Just  e -> throw e

receiveAny :: IO Dynamic
receiveAny = do
    tid <- myThreadId
    atomically $ getProcessSTM tid >>= receiveAnySTM . fromJust

receiveMatchDyn :: Typeable a => (Dynamic -> Maybe a) -> IO a
receiveMatchDyn f = do
    tid <- myThreadId
    atomically $ getProcessSTM tid >>= g [] . fromJust
  where
    g acc my = do
        d <- receiveAnySTM my
        case f d of
            Nothing -> g (d : acc) my
            Just  x -> requeue acc my >> return x
    requeue acc my = forM_ acc $ unGetTQueue $ procMailbox my

receiveMonitorMatch :: Typeable a => (a -> Bool) -> IO (Either Link a)
receiveMonitorMatch f =
    receiveMatchDyn g
  where
    g d = mon d <|> dyn d
    mon = maybe Nothing (Just . Left) . fromDynamic
    dyn d = case fromDynamic d of
        Nothing -> Nothing
        Just  x -> if f x then Just $ Right x else Nothing

receiveMonitor :: Typeable a => IO (Either Link a)
receiveMonitor =
    receiveMatchDyn f
  where
    f d = mon d <|> dyn d
    mon = maybe Nothing (Just . Left)  . fromDynamic
    dyn = maybe Nothing (Just . Right) . fromDynamic

receiveMatch :: Typeable a => (a -> Bool) -> IO a
receiveMatch f =
    receiveMatchDyn g
  where
    g d = case fromDynamic d of
        Nothing -> Nothing
        Just  x -> if f x then Just x else Nothing

receive :: Typeable a => IO a
receive = receiveMatchDyn fromDynamic

stop :: Process -> IO ()
stop proc = send proc SigStop

kill :: Process -> SomeException -> IO ()
kill proc ex = send proc $ SigKill ex
