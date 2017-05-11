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
    describe "two basic processes" $ do
        it "exchange ping/pong messages" $ do
            p <- asProcess Nothing [] $ withProcess pong $ \o -> do
                my <- myProcess
                send o (Ping, my)
                receive
            p `shouldBe` Pong
