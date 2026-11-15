{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Control.Concurrent.NQE.Conduit
-- Copyright   : Haskoin Developers
-- License     : MIT
-- Maintainer  : jprupp@protonmail.ch
-- Stability   : experimental
-- Portability : POSIX
--
-- Mix NQE processes with conduits for easy concurrent IO.
module Control.Concurrent.NQE.Conduit where

import Conduit
import Control.Concurrent.NQE.Process
import Data.Typeable

-- | Consumes messages from a 'Conduit' and sends them to a channel.
--
-- Every value received from upstream is sent to the mailbox using 'send'. If
-- the mailbox is bounded and full, the conduit blocks until there is space,
-- providing back-pressure to upstream. The conduit finishes when upstream does.
--
-- @
-- runConduit $ sourceHandle h .| conduitMailbox mailbox
-- @
--
-- This is the bridge between streaming code and processes: a conduit that reads
-- a socket or a file can feed a process directly, and a bounded mailbox turns the
-- process's pace into back-pressure on the stream.
--
-- Like the rest of NQE it runs in 'IO'. In a pipeline over another monad,
-- change its monad with @'transPipe' 'liftIO'@.
conduitMailbox ::
  (OutChan mbox, Typeable msg) =>
  mbox msg ->
  ConduitT msg o IO ()
conduitMailbox mbox = awaitForever (liftIO . (`send` mbox))
