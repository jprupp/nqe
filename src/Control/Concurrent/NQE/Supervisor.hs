{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
module Control.Concurrent.NQE.Supervisor
    ( SupervisorMessage(..)
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

data SupervisorMessage n
    = MonadUnliftIO n =>
      AddChild (n ())
               (Reply (Async ()))
    | RemoveChild (Async ())
    | StopSupervisor

data Strategy
    = Notify ((Async (), Either SomeException ()) -> STM ())
    | KillAll
    | IgnoreGraceful
    | IgnoreAll

supervisor ::
       (MonadUnliftIO m, Mailbox mbox)
    => Strategy
    -> mbox (SupervisorMessage m)
    -> [m ()]
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
        as <- atomically (readTVar state)
        mapM_ cancel as

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

startChild ::
       (MonadUnliftIO m)
    => TVar [Async ()]
    -> m ()
    -> m (Async ())
startChild state run = do
    a <- async run
    atomically (modifyTVar' state (a:))
    return a

stopChild :: MonadIO m => TVar [Async ()] -> Async () -> m ()
stopChild state a = do
    isChild <-
        atomically $ do
            cur <- readTVar state
            let new = filter (/= a) cur
            writeTVar state new
            return (cur /= new)
    when isChild (cancel a)

addChild ::
       (MonadUnliftIO n, MonadIO m, Mailbox mbox)
    => mbox (SupervisorMessage n)
    -> n ()
    -> m (Async ())
addChild mbox action = AddChild action `query` mbox

removeChild ::
       (MonadUnliftIO n, MonadIO m, Mailbox mbox)
    => mbox (SupervisorMessage n)
    -> Async ()
    -> m ()
removeChild mbox child = RemoveChild child `send` mbox

stopSupervisor ::
       (MonadUnliftIO n, MonadIO m, Mailbox mbox)
    => mbox (SupervisorMessage n)
    -> m ()
stopSupervisor mbox = StopSupervisor `send` mbox
