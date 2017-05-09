import Control.Monad
import Control.Monad.State
import Data.Dynamic
import Test.Hspec
import Control.Concurrent.NQE

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

ping :: ProcessM Int
ping = flip execStateT 0 $ do
    proc <- getProcess "pong"
    replicateM_ 4 $ do
        my <- myProcess
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
            o <- startProcess (Just "pong") pong
            i <- startProcess Nothing ping
            Right cnt <- waitFor i
            _ <- stop o
            fromDynamic cnt `shouldBe` Just (4 :: Int)
        it "exchange four ping/pong messages (withProcess)" $
            withProcess (Just "pong") pong $ \_ -> do
                withProcess Nothing ping $ \i -> do
                    Right cnt <- waitFor i
                    fromDynamic cnt `shouldBe` Just (4 :: Int)
