{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Control.Concurrent.NQE.Supervisor where

import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.NQE.Process
import           Control.Concurrent.STM
import           Control.Exception.Lifted
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.Control
import           Data.Map.Strict                      (Map)
import qualified Data.Map.Strict                      as Map
import           Data.Maybe

data Child = Child
    { childId :: String
    , childRun :: forall m. (MonadIO m, MonadBaseControl IO m, Forall (Pure m)) =>
                                m ()
    , childCanary :: Maybe SomeException -> STM ()
    }

data Status = Status { statusChild :: Child, statusAsync :: Async () }

data SupervisorState = SupervisorState
    { childMap     :: Map String Status
    , asyncMap     :: Map (Async ()) Status
    , childrenList :: [Status]
    }

data SupervisorMessage
    = AddChild Child
    | DeleteChild String
    | ChildAsync String
                 (Reply (Async ()))

data SupervisorException =
    ChildAlreadyExists String
    deriving (Eq, Show)

instance Exception SupervisorException

supervisor ::
       forall m.
       (MonadIO m, MonadBaseControl IO m, Forall (Pure m))
    => TQueue SupervisorMessage
    -> [Child]
    -> m ()
supervisor mbox children = do
    state <-
        liftIO $
        newTVarIO
            SupervisorState
            {childMap = Map.empty, asyncMap = Map.empty, childrenList = []}
    finally (forM_ children (startChild state)) (shutdown state)
  where
    shutdown state = do
        as <- atomicallyIO $ Map.keys . asyncMap <$> readTVar state
        forM_ as cancel

startChild ::
       forall m. (MonadIO m, MonadBaseControl IO m, Forall (Pure m))
    => TVar SupervisorState
    -> Child
    -> m ()
startChild state child = do
    ok <-
        atomicallyIO $
        isNothing . Map.lookup (childId child) . childMap <$> readTVar state
    unless ok . throwIO $ ChildAlreadyExists (childId child)
    a <- async (childRun child)
    let s = Status {statusChild = child, statusAsync = a}
    atomicallyIO . modifyTVar state $ \m ->
        SupervisorState
        { childMap = Map.insert (childId child) s (childMap m)
        , asyncMap = Map.insert a s (asyncMap m)
        , childrenList = s : childrenList m
        }
