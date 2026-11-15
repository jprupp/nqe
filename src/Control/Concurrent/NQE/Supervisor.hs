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
-- = Why supervisors
--
-- In a program with many threads, the dangerous failure is the quiet one: a
-- thread dies, nobody notices, and some other thread waits forever for a reply
-- that will never come. A supervisor makes the life and death of a group of
-- threads somebody's responsibility. It owns its children, it is told when one
-- stops, and it applies a policy that you chose up front.
--
-- = Design choices
--
-- * __No automatic restarts.__ Erlang supervisors restart children. NQE
--   supervisors only stop, ignore or report them. Restarting correctly needs
--   knowledge that only your code has, such as which state to start from and
--   how often a restart is acceptable, so the decision is left to you. 'Notify'
--   exists so that you can implement any restart policy you like.
--
-- * __Children run in 'IO'.__ Like everything else in NQE, a child is a plain
--   'IO' action. A supervisor outlives any one of its children and runs them
--   from its own thread, unrelated to where they were added, so there is no
--   other context that it could share with them.
--
-- * __Stopping is total.__ When a supervisor stops, for whatever reason, all
--   of its children are cancelled. Nothing it started can leak. It waits for
--   them with asynchronous exceptions blocked, so that cancelling the
--   supervisor a second time cannot make it walk away from children that are
--   still stopping. The price is that a child that refuses to die holds up
--   its supervisor.
--
-- * __A dead child is an error, however it died.__ 'KillAll' and
--   'IgnoreGraceful' re-throw the exception that stopped a child. An
--   asynchronous one, such as the t'AsyncCancelled' of a child that somebody
--   cancelled directly instead of using 'removeChild', is wrapped in
--   t'AsyncChildException' first. Thrown as it is, it would look as if the
--   supervisor itself had been cancelled, and 'link' would not report it to
--   the thread that started the supervisor.
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
    AsyncChildException (..),
    withSupervisor,
    supervisor,
    supervisorProcess,
    addChild,
    removeChild,
  )
where

import Control.Applicative
import Control.Concurrent.Async
import Control.Concurrent.NQE.Process
import Control.Concurrent.STM
import Control.Exception
  ( Exception (..),
    SomeAsyncException (..),
    SomeException,
    finally,
    mask_,
    throwIO,
    uninterruptibleMask_,
  )
import Control.Monad
import Data.List

-- | Alias for child action to be executed asynchronously by supervisor.
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
--
-- Pick the strategy by asking what a dead child means for the rest of the group.
-- If the group is useless without every child, use 'KillAll'. If children are
-- jobs that may finish but must not crash, use 'IgnoreGraceful'. If children are
-- independent, such as one per network connection, use 'IgnoreAll' or 'Notify'.
data Strategy
  = -- | run the 'Listen' action with the child handle and the exception that
    -- stopped it, or 'Nothing' if it stopped gracefully; then keep running
    Notify (Listen (Child, Maybe SomeException))
  | -- | if a child stops for any reason, kill all children and stop the
    -- supervisor; if the child threw an exception, re-throw it from the
    -- supervisor (see t'AsyncChildException')
    KillAll
  | -- | ignore children that stop without raising an exception; if a child
    -- throws, kill all children and re-throw the exception from the supervisor
    -- (see t'AsyncChildException')
    IgnoreGraceful
  | -- | keep running if a child dies and ignore it, whatever the reason
    IgnoreAll

-- | An asynchronous exception that stopped a child, as a supervisor with the
-- 'KillAll' or 'IgnoreGraceful' strategy re-throws it.
--
-- A child can die of an asynchronous exception without the supervisor having
-- asked for it: somebody cancels its 'Async' handle directly, a thread linked
-- to it fails, or the runtime sends it a stack overflow. The supervisor
-- treats that as a failure of the child like any other. It cannot throw the
-- exception unchanged, because the exception would then be taken for one
-- aimed at the supervisor: 'link' ignores a linked thread that ends with
-- t'AsyncCancelled', so the supervisor would stop without anybody noticing,
-- and handlers that let asynchronous exceptions through would not see an
-- error either. Wrapped in this type it is an ordinary, synchronous exception
-- that reaches the thread that started the supervisor.
--
-- Exceptions that are not asynchronous are re-thrown unchanged, and 'Notify'
-- always receives the original exception. The 'Show' instance and
-- 'displayException' print the exception inside, so logs read as if it had
-- not been wrapped.
newtype AsyncChildException = AsyncChildException SomeException

instance Show AsyncChildException where
  showsPrec p (AsyncChildException e) = showsPrec p e

instance Exception AsyncChildException where
  displayException (AsyncChildException e) = displayException e

-- | Run a supervisor asynchronously and pass its mailbox to a function.
-- Supervisor will be stopped along with all its children when the function
-- ends.
withSupervisor :: Strategy -> (Supervisor -> IO a) -> IO a
withSupervisor = withProcess . supervisorProcess

-- | Run a supervisor as an asynchronous process. The supervisor thread is
-- linked to the current thread, so exceptions it throws are re-thrown here. It
-- must be stopped manually; prefer 'withSupervisor' where possible.
supervisor :: Strategy -> IO Supervisor
supervisor strat = process (supervisorProcess strat)

-- | Run a supervisor in the current thread. Returns when the strategy dictates
-- that the supervisor should stop. All children are cancelled when this
-- function exits, whether normally or due to an exception.
supervisorProcess :: Strategy -> Inbox SupervisorMessage -> IO ()
supervisorProcess strat i = do
  state <- newTVarIO []
  -- 'finally' from base only masks its clean-up, which lets an asynchronous
  -- exception in while 'cancel' waits for a child to end. The children are
  -- stopped uninterruptibly instead, so that none of them is left running.
  loop state `finally` uninterruptibleMask_ (stopAll state)
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
--
-- It does not block on the child, so it is safe to call from a child of the same
-- supervisor, for example to spawn helpers.
addChild :: Supervisor -> ChildAction -> IO Child
addChild sup action = AddChild action `query` sup

-- | Stop a 'Child' controlled by this supervisor. Will block until the child
-- dies.
removeChild :: Supervisor -> Child -> IO ()
removeChild sup c = RemoveChild c `query` sup

-- | Internal function to stop all children.
stopAll :: TVar [Child] -> IO ()
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
processMessage :: TVar [Child] -> SupervisorMessage -> IO Bool
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
  TVar [Child] ->
  Strategy ->
  (Child, Either SomeException ()) ->
  IO Bool
processDead state IgnoreAll (a, _) = do
  atomically . modifyTVar' state $ filter (/= a)
  return True
processDead state KillAll (a, e) = do
  atomically $ modifyTVar' state . filter $ (/= a)
  stopAll state
  case e of
    Left x -> throwChild x
    Right () -> return False
processDead state IgnoreGraceful (a, Right ()) = do
  atomically (modifyTVar' state (filter (/= a)))
  return True
processDead state IgnoreGraceful (a, Left e) = do
  atomically $ modifyTVar' state (filter (/= a))
  stopAll state
  throwChild e
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

-- | Internal function to re-throw the exception that stopped a child from the
-- supervisor. An asynchronous exception is wrapped in t'AsyncChildException',
-- so that it is thrown as a failure of the child and not mistaken for an
-- exception sent to the supervisor itself.
throwChild :: SomeException -> IO a
throwChild e =
  case fromException e of
    Just (SomeAsyncException _) -> throwIO (AsyncChildException e)
    Nothing -> throwIO e

-- | Internal function to start a child process.
startChild :: TVar [Child] -> ChildAction -> IO Child
startChild state ch = mask_ $ do
  a <- async ch
  atomically $ modifyTVar' state (a :)
  return a

-- | Internal fuction to stop a child process.
stopChild :: TVar [Child] -> Child -> IO ()
stopChild state a = mask_ $ do
  isChild <-
    atomically $ do
      cur <- readTVar state
      let new = filter (/= a) cur
      writeTVar state new
      return (cur /= new)
  when isChild $ cancel a
