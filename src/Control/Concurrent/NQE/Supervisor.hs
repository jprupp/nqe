{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
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
import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.NQE.Process
import           Control.Concurrent.STM
import           Control.Exception.Lifted
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control

type ActorAsync = Async ()
type ActorReturn = Either SomeException ()

data SupervisorMessage m
    = AddChild (m ())
               (Reply ActorAsync)
    | RemoveChild ActorAsync
    | StopSupervisor

data Strategy
    = Notify ((ActorAsync, ActorReturn) -> STM ())
    | KillAll
    | IgnoreGraceful
    | IgnoreAll

supervisor ::
       (MonadIO m, MonadBaseControl IO m, Forall (Pure m), Mailbox mbox)
    => Strategy
    -> mbox (SupervisorMessage m)
    -> [m ()]
    -> m ()
supervisor strat mbox children = do
    state <- liftIO $ newTVarIO []
    finally (go state) (down state)
  where
    go state = do
        mapM_ (startChild state) children
        loop state
    loop state = do
        e <-
            liftIO . atomically $
            Right <$> receiveSTM mbox <|> Left <$> waitForChild state
        again <- case e of
            Right m -> processMessage state m
            Left x  -> processDead state strat x
        when again $ loop state
    down state = do
        as <- liftIO . atomically $ readTVar state
        mapM_ cancel as

waitForChild :: TVar [ActorAsync] -> STM (ActorAsync, ActorReturn)
waitForChild state = do
    as <- readTVar state
    waitAnyCatchSTM as

processMessage ::
       (MonadIO m, MonadBaseControl IO m, Forall (Pure m))
    => TVar [ActorAsync]
    -> SupervisorMessage m
    -> m Bool
processMessage state (AddChild ch r) = do
    a <- async ch
    liftIO . atomically $ do
        modifyTVar' state (a:)
        r a
    return True
processMessage state (RemoveChild a) = do
    liftIO . atomically $ modifyTVar' state (filter (/= a))
    cancel a
    return True
processMessage state StopSupervisor = do
    as <- liftIO $ readTVarIO state
    forM_ as (stopChild state)
    return False

processDead ::
       (MonadIO m, MonadBaseControl IO m)
    => TVar [ActorAsync]
    -> Strategy
    -> (ActorAsync, ActorReturn)
    -> m Bool
processDead state IgnoreAll (a, _) = do
    liftIO . atomically $ modifyTVar' state (filter (/= a))
    return True

processDead state KillAll (a, e) = do
    as <- liftIO . atomically $ do
        modifyTVar' state (filter (/= a))
        readTVar state
    mapM_ (stopChild state) as
    case e of
        Left x   -> throw x
        Right () -> return False

processDead state IgnoreGraceful (a, Right ()) = do
    liftIO . atomically $ modifyTVar' state (filter (/= a))
    return True

processDead state IgnoreGraceful (a, Left e) = do
    as <- liftIO . atomically $ do
        modifyTVar' state (filter (/= a))
        readTVar state
    mapM_ (stopChild state) as
    throw e

processDead state (Notify notif) (a, e) = do
    x <-
        liftIO . atomically $ do
            modifyTVar' state (filter (/= a))
            catchSTM (notif (a, e) >> return Nothing) $ \x ->
                return $ Just (x :: SomeException)
    case x of
        Nothing -> return True
        Just ex -> do
            as <- liftIO $ readTVarIO state
            forM_ as (stopChild state)
            throwIO ex

startChild ::
       (MonadIO m, MonadBaseControl IO m, Forall (Pure m))
    => TVar [ActorAsync]
    -> m ()
    -> m ActorAsync
startChild state run = do
    a <- async run
    liftIO . atomically $ modifyTVar' state (a:)
    return a

stopChild ::
       (MonadIO m, MonadBase IO m) => TVar [ActorAsync] -> ActorAsync -> m ()
stopChild state a = do
    isChild <-
        liftIO . atomically $ do
            cur <- readTVar state
            let new = filter (/= a) cur
            writeTVar state new
            return $ cur /= new
    when isChild $ cancel a

addChild ::
       (MonadIO m, Mailbox mbox)
    => mbox (SupervisorMessage m)
    -> m ()
    -> m ActorAsync
addChild mbox action = AddChild action `query` mbox

removeChild ::
       (MonadIO m, Mailbox mbox)
    => mbox (SupervisorMessage m)
    -> ActorAsync
    -> m ()
removeChild mbox child = RemoveChild child `send` mbox

stopSupervisor ::
       (MonadIO m, Mailbox mbox) => mbox (SupervisorMessage m) -> m ()
stopSupervisor mbox = StopSupervisor `send` mbox
