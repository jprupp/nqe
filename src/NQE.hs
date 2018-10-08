{-|
Module      : NQE
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Concurrency library inspired by Erlang/OTP.
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
