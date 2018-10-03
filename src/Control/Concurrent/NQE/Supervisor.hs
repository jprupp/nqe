{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
module Control.Concurrent.NQE.Supervisor where

import           Control.Applicative
import           Control.Concurrent.NQE.Process
import           Control.Monad
import           Data.Hashable
import           Data.List
import           UnliftIO

type ChildAction = IO ()
type Child = Async ()

data SupervisorMessage
    = AddChild !ChildAction
               !(Reply Child)
    | RemoveChild !Child
                  !(Reply ())
    deriving (Typeable)

data SupervisorNotif = ChildStopped
    { childStopped   :: !Child
    , childException :: !(Maybe SomeException)
    }

instance Show SupervisorNotif where
    show (ChildStopped _ e) = show e

newtype Supervisor = Supervisor Process
    deriving (Eq, Hashable, Typeable, OutChan)

-- | Supervisor strategies to decide what to do when a child stops.
data Strategy
    = Notify Mailbox
    -- ^ send a 'SupervisorNotif' to 'Mailbox' when child dies
    | KillAll
    -- ^ kill all processes and propagate exception upstream
    | IgnoreGraceful
    -- ^ ignore processes that stop without raising an exception
    | IgnoreAll
    -- ^ keep running if a child dies and ignore it

-- | Run a supervisor with a given 'Strategy' and a list of 'ChildAction' to run
-- as children. Supervisor will be stopped along with all its children when
-- provided action ends.
withSupervisor ::
       MonadUnliftIO m
    => Strategy
    -> [ChildAction]
    -> (Supervisor -> m a)
    -> m a
withSupervisor strat cs f =
    withProcess (supervisorProcess strat cs) $ f . Supervisor

-- | Run a supervisor with a given 'Strategy' and a list of 'ChildAction' to run
-- as children.
supervisor :: MonadUnliftIO m => Strategy -> [ChildAction] -> m Supervisor
supervisor strat cs = Supervisor <$> process (supervisorProcess strat cs)

-- | Run a supervisor with a given 'Strategy' and a list of 'ChildAction' to
-- run.
supervisorProcess ::
       MonadUnliftIO m
    => Strategy
    -> [ChildAction]
    -> Inbox
    -> m ()
supervisorProcess strat cs i = do
    state <- newTVarIO []
    finally (go state) (down state)
  where
    go state = do
        mapM_ (startChild state) cs
        loop state
    loop state = do
        e <- atomically $ Right <$> receiveSTM i <|> Left <$> waitForChild state
        again <-
            case e of
                Right m -> processMessage state m
                Left x  -> processDead state strat x
        when again $ loop state
    down state = do
        ps <- readTVarIO state
        mapM_ cancel ps

-- | Internal action to wait for a child process to finish running.
waitForChild :: TVar [Child] -> STM (Child, Either SomeException ())
waitForChild state = do
    as <- readTVar state
    waitAnyCatchSTM as

processMessage ::
       MonadUnliftIO m => TVar [Child] -> SupervisorMessage -> m Bool
processMessage state (AddChild ch r) = do
    a <- liftIO (async ch)
    atomically $ do
        modifyTVar' state (a :)
        r a
    return True

processMessage state (RemoveChild a r) = do
    atomically (modifyTVar' state (filter (/= a)))
    cancel a
    atomically $ r ()
    return True

-- | Internal function to run when a child process dies.
processDead ::
       MonadUnliftIO m
    => TVar [Child]
    -> Strategy
    -> (Child, Either SomeException ())
    -> m Bool
processDead state IgnoreAll (a, _) = do
    atomically . modifyTVar' state $ filter (/= a)
    return True

processDead state KillAll (a, e) = do
    as <-
        atomically $ do
            modifyTVar' state . filter $ (/= a)
            readTVar state
    mapM_ (stopChild state) as
    case e of
        Left x   -> throwIO x
        Right () -> return False

processDead state IgnoreGraceful (a, Right ()) = do
    atomically (modifyTVar' state (filter (/= a)))
    return True

processDead state IgnoreGraceful (a, Left e) = do
    as <-
        atomically $ do
            modifyTVar' state (filter (/= a))
            readTVar state
    mapM_ (stopChild state) as
    throwIO e

processDead state (Notify notif) (a, ee) = do
    atomically $ do
        as <- readTVar state
        modifyTVar state (filter (/= a))
        case find (== a) as of
            Just p  -> ChildStopped p me `sendSTM` notif
            Nothing -> return ()
    return True
  where
    me =
        case ee of
            Left e   -> Just e
            Right () -> Nothing

-- | Internal function to start a child process.
startChild :: MonadUnliftIO m => TVar [Child] -> ChildAction -> m Child
startChild state ch = do
    a <- liftIO $ async ch
    atomically $ modifyTVar' state (a :)
    return a

-- | Internal fuction to stop a child process.
stopChild :: MonadUnliftIO m => TVar [Child] -> Child -> m ()
stopChild state a = do
    isChild <-
        atomically $ do
            cur <- readTVar state
            let new = filter (/= a) cur
            writeTVar state new
            return (cur /= new)
    when isChild $ cancel a

-- | Add a new 'ChildAction' to the supervisor. Will return a 'Process' for the
-- child. This function will not block or raise an exception if the child dies.
addChild :: MonadIO m => Supervisor -> ChildAction -> m Child
addChild sup action = AddChild action `query` sup

-- | Stop a child process controlled by the supervisor. Must pass the child
-- 'Process'. Will block until the child dies.
removeChild :: MonadIO m => Supervisor -> Child -> m ()
removeChild sup c = RemoveChild c `query` sup
