import Control.Exception
import Control.Monad
import Data.Dynamic
import Test.Hspec
import Control.Concurrent.NQE

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

data IKillYou = IKillYou deriving (Eq, Show, Typeable)
instance Exception IKillYou

pong :: ProcessSpec
pong = ProcessSpec
    { provides = Just "pong"
    , depends  = []
    , action = forever $ do
        (Ping, proc) <- receive
        send proc Pong
    }

dispatch :: ProcessSpec
dispatch = ProcessSpec
    { provides = Just "dispatch"
    , depends = ["recipient"]
    , action = getProcess "recipient" >>= \r -> forever $ receiveAny
        [ Case $ \i -> seq (i :: Int) send r "int"
        , Case $ \t -> seq (t :: String) send r "string"
        , Default $ send r "default"
        ]
    }

ooo :: ProcessSpec
ooo = ProcessSpec
    { provides = Just "out-of-order"
    , depends = ["recipient"]
    , action = do
        r <- getProcess "recipient"
        msg1 <- receiveMatch (==1)
        send r (msg1 :: Int)
        msg2 <- receiveMatch (==2)
        send r (msg2 :: Int)
        msg3 <- receiveMatch (==3)
        send r (msg3 :: Int)
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
        it "one monitors and kills another" $ do
            (sig, tid) <- asProcess Nothing [] $
                withProcess pong $ \s -> do
                    monitor s
                    kill s $ toException IKillYou
                    sig <- receive
                    return (sig, thread s)
            remoteThread sig `shouldBe` tid
            fromException (remoteError sig) `shouldBe` Just IKillYou
        it "dispatch multiple types of message" $ do
            types <- asProcess (Just "recipient") [] $
                withProcess dispatch $ \d -> do
                    send d "This is a string"
                    send d (42 :: Int)
                    send d ["List", "of", "strings"]
                    replicateM 3 receive
            types `shouldBe` ["string", "int", "default"]
        it "process messages out of order if needed" $ do
            messages <- asProcess (Just "recipient") [] $
                withProcess ooo $ \o -> do
                    send o (2 :: Int)
                    send o (3 :: Int)
                    send o (1 :: Int)
                    replicateM 3 receive
            messages `shouldBe` ([1, 2, 3] :: [Int])
