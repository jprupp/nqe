module Control.Concurrent.NQE.Supervisor
    ( SupervisorMessage(..)
    , Strategy(..)
    , supervisor
    ) where

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Concurrent.NQE.Process
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad

type ActorAsync = Async ()
type ActorFinished = Either SomeException ()
type ActorDied = (ActorAsync, ActorFinished)
type ActorAction = IO ()

data SupervisorMessage
    = AddChild ActorAction (Reply ActorAsync)
    | RemoveChild ActorAsync
    | StopSupervisor

data Strategy
    = Notify (ActorDied -> IO ())
    | KillAll
    | IgnoreGraceful
    | IgnoreAll

supervisor ::
       Mailbox mbox
    => Strategy
    -> mbox SupervisorMessage
    -> [ActorAction]
    -> IO ()
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
        case e of
            Right m -> processMessage state m >> loop state
            Left x ->
                processDead state strat x >>= \again -> when again $ loop state
    down state = do
        as <- atomically $ readTVar state
        mapM_ cancel as

waitForChild :: TVar [ActorAsync] -> STM ActorDied
waitForChild state = do
    as <- readTVar state
    waitAnyCatchSTM as

processMessage :: TVar [ActorAsync] -> SupervisorMessage -> IO ()
processMessage state (AddChild ch r) = do
    a <- async ch
    atomically $ do
        modifyTVar' state (a:)
        r a
processMessage state (RemoveChild a) = do
    atomically $ modifyTVar' state (filter (/= a))
    cancel a
processMessage state StopSupervisor = do
    as <- readTVarIO state
    forM_ as (stopChild state)

processDead ::
       TVar [ActorAsync]
    -> Strategy
    -> ActorDied
    -> IO Bool
processDead state IgnoreAll (a, _) = do
    atomically $ modifyTVar' state (filter (/= a))
    return True
processDead state KillAll (a, e) = do
    as <- atomically $ do
        modifyTVar' state (filter (/= a))
        readTVar state
    mapM_ (stopChild state) as
    case e of
        Left x   -> throw x
        Right () -> return False
processDead state IgnoreGraceful (a, Right ()) = do
    atomically $ modifyTVar' state (filter (/= a))
    return True
processDead state IgnoreGraceful (a, Left e) = do
    as <- atomically $ do
        modifyTVar' state (filter (/= a))
        readTVar state
    mapM_ (stopChild state) as
    throw e
processDead state (Notify notif) (a, e) = do
    atomically $ modifyTVar' state (filter (/= a))
    catch (notif (a, e) >> return True) $ \x -> do
        as <- readTVarIO state
        mapM_ (stopChild state) as
        throw (x :: SomeException)

startChild :: TVar [ActorAsync] -> IO () -> IO ActorAsync
startChild state run = do
    a <- async run
    atomically $ modifyTVar' state (a:)
    return a

stopChild ::
    TVar [ActorAsync]
    -> ActorAsync
    -> IO ()
stopChild state a = do
    isChild <- atomically $ do
        cur <- readTVar state
        let new = filter (/= a) cur
        writeTVar state new
        return $ cur /= new
    when isChild $ cancel a
