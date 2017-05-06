import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Data.Dynamic
import Test.Hspec
import Control.Concurrent.NQE

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

ping :: Process -> ProcessM Int
ping proc = flip execStateT 0 $ replicateM_ 4 $ do
    my <- lift ask
    send proc (Ping, my)
    Pong <- receive
    modify (+1)

pong :: ProcessM ()
pong = forever $ do
    (Ping, proc) <- receive
    send proc Pong

main :: IO ()
main = hspec $ do
    describe "two basic processes" $ do
        it "exchange four ping/pong messages (startProcess)" $ do
            o <- startProcess pong
            i <- startProcess (ping o)
            Right cnt <- waitFor i
            _ <- stop o
            fromDynamic cnt `shouldBe` Just (4 :: Int)
        it "exchange four ping/pong messages (withProcess)" $
            withProcess pong $ \o ->
            withProcess (ping o) $ \i -> do
            Right cnt <- waitFor i
            fromDynamic cnt `shouldBe` Just (4 :: Int)
