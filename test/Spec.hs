import Control.Monad
import Data.Typeable
import Test.Hspec
import Control.Concurrent.NQE

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

ping :: Process -> Process -> IO ()
ping proc my = replicateM_ 4 $ do
    send proc (my, Ping)
    Pong <- receive
    return ()

pong :: Process -> IO ()
pong _ = forever $ do
    (proc, Ping) <- receive
    send proc Pong

usingWithProcess :: IO ()
usingWithProcess =
    withProcess "pong" pong $ \ po ->
    withProcess "ping" (ping po) $ \ pi ->
    waitFor pi

usingStartProcess :: IO ()
usingStartProcess = do
    po <- startProcess "pong" pong
    pi <- startProcess "ping" (ping po)
    waitFor pi

main :: IO ()
main = hspec $ do
    describe "two processses exchange ping/pong messages" $ do
        it "launched via startProcess" $
            usingStartProcess
        it "launched via withProcess" $
            usingWithProcess
