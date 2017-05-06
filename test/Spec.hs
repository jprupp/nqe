import Control.Monad
import Control.Monad.Reader
import Data.Typeable
import Test.Hspec
import Control.Concurrent.NQE

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

ping :: Process -> ProcessM ()
ping proc = replicateM_ 4 $ do
    my <- ask
    send proc (Ping, my)
    Pong <- receive
    return ()

pong :: ProcessM ()
pong = forever $ do
    (Ping, proc) <- receive
    send proc Pong

main :: IO ()
main = hspec $ do
    describe "two processses exchange ping/pong messages" $ do
        it "launched via startProcess" $ do
            o <- startProcess pong
            i <- startProcess (ping o)
            waitFor i
            stop o
        it "launched via withProcess" $
            withProcess pong $ \o ->
            withProcess (ping o) $ \i ->
            waitFor i
