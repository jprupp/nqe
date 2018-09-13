{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
module Control.Concurrent.NQE.Supervisor
    ( SupervisorMessage
    , Strategy(..)
    , supervisor
    , addChild
    , removeChild
    , stopSupervisor
    ) where

import           Control.Applicative
import           Control.Concurrent.NQE.Process
import           Control.Monad
import           Control.Monad.STM              (catchSTM)
import           UnliftIO

-- | A supervisor will start, stop and monitor processes.
data SupervisorMessage n
    = MonadUnliftIO n =>
      AddChild (n ())
               (Reply (Async ()))
    | RemoveChild (Async ())
    | StopSupervisor

-- | Supervisor strategies to decide what to do when a child stops.
data Strategy
    = Notify ((Async (), Either SomeException ()) -> STM ())
    -- ^ run this 'STM' action when a process stops
    | KillAll
    -- ^ kill all processes and propagate exception
    | IgnoreGraceful
    -- ^ ignore processes that stop without raising exceptions
    | IgnoreAll
    -- ^ do nothing and keep running if a process dies

-- | Run a supervisor with a given 'Strategy' a 'Mailbox' to control it, and a
-- list of children to launch. The list can be empty.
supervisor ::
       (MonadUnliftIO m, Mailbox mbox (SupervisorMessage n), m ~ n)
    => Strategy
    -> mbox (SupervisorMessage n)
    -> [n ()]
    -> m ()
supervisor strat mbox children = do
    state <- newTVarIO []
    finally (go state) (down state)
  where
    go state = do
        mapM_ (startChild state) children
        loop state
    loop state = do
        e <-
            atomically $
            Right <$> receiveSTM mbox <|> Left <$> waitForChild state
        again <-
            case e of
                Right m -> processMessage state m
                Left x  -> processDead state strat x
        when again $ loop state
    down state = do
        as <- readTVarIO state
        mapM_ cancel as

-- | Internal action to wait for a child process to finish running.
waitForChild :: TVar [Async ()] -> STM (Async (), Either SomeException ())
waitForChild state = do
    as <- readTVar state
    waitAnyCatchSTM as

processMessage ::
       (MonadUnliftIO m)
    => TVar [Async ()]
    -> SupervisorMessage m
    -> m Bool
processMessage state (AddChild ch r) = do
    a <- async ch
    atomically $ do
        modifyTVar' state (a:)
        r a
    return True

processMessage state (RemoveChild a) = do
    atomically (modifyTVar' state (filter (/= a)))
    cancel a
    return True

processMessage state StopSupervisor = do
    as <- readTVarIO state
    forM_ as (stopChild state)
    return False

processDead ::
       (MonadIO m)
    => TVar [Async ()]
    -> Strategy
    -> (Async (), Either SomeException ())
    -> m Bool
processDead state IgnoreAll (a, _) = do
    atomically (modifyTVar' state (filter (/= a)))
    return True

processDead state KillAll (a, e) = do
    as <- atomically $ do
        modifyTVar' state (filter (/= a))
        readTVar state
    mapM_ (stopChild state) as
    case e of
        Left x   -> throwIO x
        Right () -> return False

processDead state IgnoreGraceful (a, Right ()) = do
    atomically (modifyTVar' state (filter (/= a)))
    return True

processDead state IgnoreGraceful (a, Left e) = do
    as <- atomically $ do
        modifyTVar' state (filter (/= a))
        readTVar state
    mapM_ (stopChild state) as
    throwIO e

processDead state (Notify notif) (a, e) = do
    x <-
        atomically $ do
            modifyTVar' state (filter (/= a))
            catchSTM (notif (a, e) >> return Nothing) $ \x ->
                return $ Just (x :: SomeException)
    case x of
        Nothing -> return True
        Just ex -> do
            as <- readTVarIO state
            forM_ as (stopChild state)
            throwIO ex

-- | Internal function to start a child process.
startChild ::
       (MonadUnliftIO m)
    => TVar [Async ()]
    -> m ()
    -> m (Async ())
startChild state run = do
    a <- async run
    atomically (modifyTVar' state (a:))
    return a

-- | Internal fuction to stop a child process.
stopChild :: MonadIO m => TVar [Async ()] -> Async () -> m ()
stopChild state a = do
    isChild <-
        atomically $ do
            cur <- readTVar state
            let new = filter (/= a) cur
            writeTVar state new
            return (cur /= new)
    when isChild (cancel a)

-- | Add a new child process to the supervisor. The child process will run in
-- the supervisor context. Will return an 'Async' for the child. This function
-- will not block or raise an exception if the child dies.
addChild ::
       (MonadUnliftIO n, MonadIO m, Mailbox mbox (SupervisorMessage n))
    => mbox (SupervisorMessage n)
    -> n ()
    -> m (Async ())
addChild mbox action = AddChild action `query` mbox

-- | Stop a child process controlled by the supervisor. Must pass the child
-- 'Async'. Will not wait for the child to die.
removeChild ::
       (MonadUnliftIO n, MonadIO m, Mailbox mbox (SupervisorMessage n))
    => mbox (SupervisorMessage n)
    -> Async ()
    -> m ()
removeChild mbox child = RemoveChild child `send` mbox

-- | Stop the supervisor and its children.
stopSupervisor ::
       (MonadUnliftIO n, MonadIO m, Mailbox mbox (SupervisorMessage n))
    => mbox (SupervisorMessage n)
    -> m ()
stopSupervisor mbox = StopSupervisor `send` mbox
