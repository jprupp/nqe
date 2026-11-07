{-|
Module      : NQE
Copyright   : Haskoin Developers
License     : MIT
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

Concurrency library inspired by Erlang/OTP.

This module re-exports everything in the library:

* "Control.Concurrent.NQE.Process": processes, inboxes, mailboxes and
  synchronous queries.
* "Control.Concurrent.NQE.Supervisor": supervisors that start, monitor and stop
  child threads.
* "Control.Concurrent.NQE.Publisher": a process that broadcasts messages to any
  number of subscribers.
* "Control.Concurrent.NQE.Conduit": glue to feed a 'Data.Conduit.ConduitT'
  stream into a mailbox.
-}
module NQE
    ( -- * Processes and Mailboxes
      module Process
      -- * Process Supervisors
    , module Supervisor
      -- * Publisher and Subscribers
    , module Publisher
      -- * Conduit Integration
    , module Conduit
    ) where

import           Control.Concurrent.NQE.Conduit    as Conduit
import           Control.Concurrent.NQE.Process    as Process
import           Control.Concurrent.NQE.Publisher  as Publisher
import           Control.Concurrent.NQE.Supervisor as Supervisor
