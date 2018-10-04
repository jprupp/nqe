{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
module Control.Concurrent.NQE.Supervisor where

import           Control.Applicative
import           Control.Concurrent.NQE.Process
import           Control.Monad
import           Data.List
import           UnliftIO

-- | Alias for child action to be executed asynchronously by supervisor.
type ChildAction = IO ()

-- | Thread handler for child.
type Child = Async ()

-- | Send this message to a supervisor to add or remove a child.
data SupervisorMessage
    = AddChild !ChildAction
               !(Listen Child)
    | RemoveChild !Child
                  !(Listen ())

-- | Supervisor notifications sent when a process dies.
data SupervisorNotif = ChildStopped
    { childStopped   :: !Child
    , childException :: !(Maybe SomeException)
    }

type Supervisor = Process SupervisorMessage

-- | Supervisor strategies to decide what to do when a child stops.
data Strategy
    = Notify (Listen (Child, Maybe SomeException))
    -- ^ send a 'SupervisorNotif' to 'Mailbox' when child dies
    | KillAll
    -- ^ kill all processes and propagate exception upstream
    | IgnoreGraceful
    -- ^ ignore processes that stop without raising an exception
    | IgnoreAll
    -- ^ keep running if a child dies and ignore it

-- | Run a supervisor with a given 'Strategy'. Supervisor will be stopped along
-- with all its children when function on last argument finishes.
withSupervisor ::
       MonadUnliftIO m
    => Strategy
    -> (Supervisor -> m a)
    -> m a
withSupervisor = withProcess . supervisorProcess

-- | Run a supervisor with a given 'Strategy'.
supervisor :: MonadUnliftIO m => Strategy -> m Supervisor
supervisor strat = process (supervisorProcess strat)

-- | Run a supervisor with a given 'Strategy'.
supervisorProcess ::
       MonadUnliftIO m
    => Strategy
    -> Inbox SupervisorMessage
    -> m ()
supervisorProcess strat i = do
    state <- newTVarIO []
    finally (loop state) (stopAll state)
  where
    loop state = do
        e <- atomically $ Right <$> receiveSTM i <|> Left <$> waitForChild state
        again <-
            case e of
                Right m -> processMessage state m
                Left x  -> processDead state strat x
        when again $ loop state

stopAll :: MonadUnliftIO m => TVar [Child] -> m ()
stopAll state = mask_ $ do
    as <- readTVarIO state
    mapM_ cancel as

-- | Internal function to wait for a child process to finish running.
waitForChild :: TVar [Child] -> STM (Child, Either SomeException ())
waitForChild state = do
    as <- readTVar state
    waitAnyCatchSTM as

-- | Internal function to process incoming supervisor message.
processMessage ::
       MonadUnliftIO m => TVar [Child] -> SupervisorMessage -> m Bool
processMessage state (AddChild ch r) = do
    a <- startChild state ch
    atomically $ r a
    return True

processMessage state (RemoveChild a r) = do
    stopChild state a
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
    atomically $ modifyTVar' state . filter $ (/= a)
    stopAll state
    case e of
        Left x -> throwIO x
        Right () -> return False

processDead state IgnoreGraceful (a, Right ()) = do
    atomically (modifyTVar' state (filter (/= a)))
    return True

processDead state IgnoreGraceful (a, Left e) = do
    atomically $ modifyTVar' state (filter (/= a))
    stopAll state
    throwIO e

processDead state (Notify notif) (a, ee) = do
    atomically $ do
        as <- readTVar state
        case find (== a) as of
            Just p  -> notif (p, me)
            Nothing -> return ()
        modifyTVar state (filter (/= a))
    return True
  where
    me =
        case ee of
            Left e   -> Just e
            Right () -> Nothing

-- | Internal function to start a child process.
startChild :: MonadUnliftIO m => TVar [Child] -> ChildAction -> m Child
startChild state ch = mask_ $ do
    a <- liftIO $ async ch
    atomically $ modifyTVar' state (a :)
    return a

-- | Internal fuction to stop a child process.
stopChild :: MonadUnliftIO m => TVar [Child] -> Child -> m ()
stopChild state a = mask_ $ do
    isChild <-
        atomically $ do
            cur <- readTVar state
            let new = filter (/= a) cur
            writeTVar state new
            return (cur /= new)
    when isChild $ cancel a

-- | Add a new 'ChildAction' to the supervisor. Will return the 'Child' child
-- that was just started. This function will not block or raise an exception if
-- the child dies.
addChild :: MonadIO m => Supervisor -> ChildAction -> m Child
addChild sup action = AddChild action `query` sup

-- | Stop a 'Child' controlled by this supervisor. Must pass the child
-- 'Process'. Will block until the child dies.
removeChild :: MonadIO m => Supervisor -> Child -> m ()
removeChild sup c = RemoveChild c `query` sup
