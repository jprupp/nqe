{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types #-}

-- |
-- Module      : Control.Concurrent.NQE.Supervisor
-- Copyright   : Haskoin Developers
-- License     : MIT
-- Maintainer  : jprupp@protonmail.ch
-- Stability   : experimental
-- Portability : POSIX
--
-- Supervisors run and monitor processes, including other supervisors. A supervisor
-- has a corresponding 'Strategy' that controls its behaviour if a child stops.
-- Supervisors deal with exceptions in concurrent processes so that their code does
-- not need to be written in an overly-defensive style. They help prevent problems
-- caused by processes dying quietly in the background, potentially locking an
-- entire application.
--
-- A child is any @IO ()@ action. It is started with 'addChild', which returns
-- its 'Async' handle, and can be stopped with 'removeChild'. When the supervisor
-- itself stops, all of its children are cancelled.
--
-- @
-- 'withSupervisor' 'KillAll' $ \\sup -> do
--     _ <- 'addChild' sup worker1
--     _ <- 'addChild' sup worker2
--     mainLoop
-- @
module Control.Concurrent.NQE.Supervisor
  ( ChildAction,
    Child,
    SupervisorMessage,
    Supervisor,
    Strategy (..),
    withSupervisor,
    supervisor,
    supervisorProcess,
    addChild,
    removeChild,
  )
where

import Control.Applicative
import Control.Concurrent.NQE.Process
import Control.Concurrent.STM (retry)
import Control.Monad
import Data.List
import UnliftIO

-- | Alias for child action to be executed asynchronously by supervisor. Use
-- 'UnliftIO.toIO' or 'UnliftIO.withRunInIO' to turn an action in another monad
-- into a 'ChildAction'.
type ChildAction = IO ()

-- | Thread handler for child. Returned by 'addChild' and used to remove the
-- child with 'removeChild', or to identify it in a 'Notify' callback.
type Child = Async ()

-- | Send this message to a supervisor to add or remove a child. Normally these
-- messages are sent using 'addChild' and 'removeChild'.
data SupervisorMessage
  = -- | start a child and reply with its handle
    AddChild
      !ChildAction
      !(Listen Child)
  | -- | stop a child and reply once it is stopped
    RemoveChild
      !Child
      !(Listen ())

-- | Alias for supervisor process. Since it is a 'Process', it can be stopped by
-- cancelling 'getProcessAsync', which also cancels all its children.
type Supervisor = Process SupervisorMessage

-- | Supervisor strategies to decide what to do when a child stops.
data Strategy
  = -- | run the 'Listen' action with the child handle and the exception that
    -- stopped it, or 'Nothing' if it stopped gracefully; then keep running
    Notify (Listen (Child, Maybe SomeException))
  | -- | if a child stops for any reason, kill all children and stop the
    -- supervisor; if the child threw an exception, re-throw it from the
    -- supervisor
    KillAll
  | -- | ignore children that stop without raising an exception; if a child
    -- throws, kill all children and re-throw the exception from the supervisor
    IgnoreGraceful
  | -- | keep running if a child dies and ignore it, whatever the reason
    IgnoreAll

-- | Run a supervisor asynchronously and pass its mailbox to a function.
-- Supervisor will be stopped along with all its children when the function
-- ends.
withSupervisor ::
  (MonadUnliftIO m) =>
  Strategy ->
  (Supervisor -> m a) ->
  m a
withSupervisor = withProcess . supervisorProcess

-- | Run a supervisor as an asynchronous process. The supervisor thread is
-- linked to the current thread, so exceptions it throws are re-thrown here. It
-- must be stopped manually; prefer 'withSupervisor' where possible.
supervisor :: (MonadUnliftIO m) => Strategy -> m Supervisor
supervisor strat = process (supervisorProcess strat)

-- | Run a supervisor in the current thread. Returns when the strategy dictates
-- that the supervisor should stop. All children are cancelled when this
-- function exits, whether normally or due to an exception.
supervisorProcess ::
  (MonadUnliftIO m) =>
  Strategy ->
  Inbox SupervisorMessage ->
  m ()
supervisorProcess strat i = do
  state <- newTVarIO []
  finally (loop state) (stopAll state)
  where
    loop state = do
      e <- atomically $ Right <$> receiveSTM i <|> Left <$> waitForChild state
      again <-
        case e of
          Right m -> processMessage state m
          Left x -> processDead state strat x
      when again $ loop state

-- | Add a new 'ChildAction' to the supervisor. Will return the 'Child' that was
-- just started. This function will not block or raise an exception if the child
-- dies.
addChild :: (MonadIO m) => Supervisor -> ChildAction -> m Child
addChild sup action = AddChild action `query` sup

-- | Stop a 'Child' controlled by this supervisor. Will block until the child
-- dies.
removeChild :: (MonadIO m) => Supervisor -> Child -> m ()
removeChild sup c = RemoveChild c `query` sup

-- | Internal function to stop all children.
stopAll :: (MonadUnliftIO m) => TVar [Child] -> m ()
stopAll state = mask_ $ do
  as <- readTVarIO state
  mapM_ cancel as

-- | Internal function to wait for a child process to finish running.
waitForChild :: TVar [Child] -> STM (Child, Either SomeException ())
waitForChild state = do
  as <- readTVar state
  when (null as) retry
  waitAnyCatchSTM as

-- | Internal function to process incoming supervisor message.
processMessage ::
  (MonadUnliftIO m) => TVar [Child] -> SupervisorMessage -> m Bool
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
  (MonadUnliftIO m) =>
  TVar [Child] ->
  Strategy ->
  (Child, Either SomeException ()) ->
  m Bool
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
      Just p -> notif (p, me)
      Nothing -> return ()
    modifyTVar state (filter (/= a))
  return True
  where
    me =
      case ee of
        Left e -> Just e
        Right () -> Nothing

-- | Internal function to start a child process.
startChild :: (MonadUnliftIO m) => TVar [Child] -> ChildAction -> m Child
startChild state ch = mask_ $ do
  a <- liftIO $ async ch
  atomically $ modifyTVar' state (a :)
  return a

-- | Internal fuction to stop a child process.
stopChild :: (MonadUnliftIO m) => TVar [Child] -> Child -> m ()
stopChild state a = mask_ $ do
  isChild <-
    atomically $ do
      cur <- readTVar state
      let new = filter (/= a) cur
      writeTVar state new
      return (cur /= new)
  when isChild $ cancel a
