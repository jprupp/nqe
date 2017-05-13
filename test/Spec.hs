import Control.Exception
import Control.Monad
import Data.Dynamic
import Test.Hspec
import Control.Concurrent.NQE

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

pong :: ProcessSpec
pong = ProcessSpec
    { provides = Just "pong"
    , depends  = []
    , action = forever $ do
        (Ping, proc) <- receive
        send proc Pong
    }

main :: IO ()
main = hspec $ do
    describe "two communicating processes" $ do
        it "exchange ping/pong messages" $ do
            p <- asProcess Nothing [] $
                withProcess pong $ \o -> do
                    my <- myProcess
                    send o (Ping, my)
                    receive
            p `shouldBe` Pong
        it "one monitors and stops another" $ do
            (sig, tid) <- asProcess Nothing [] $
                withProcess pong $ \s -> do
                    monitor s
                    stop s
                    sig <- receive
                    return (sig, thread s)
            remoteThread sig `shouldBe` tid
            fromException (remoteError sig) `shouldBe` Just Stopped
