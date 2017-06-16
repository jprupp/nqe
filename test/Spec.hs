import           Control.Concurrent.NQE
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Control.Monad.State
import           Data.Dynamic
import           Test.Hspec

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

pong :: IO ()
pong = forever $ respond $ \Ping -> return Pong

dispatch :: IO ()
dispatch = evalStateT (forever $ receiveAny handlers) Nothing
  where
    handlers =
        [ Case receiveProcess
        , Case receiveInt
        , Case receiveString
        , Default receiveDefault
        ]
    receiveProcess :: Process -> StateT (Maybe Process) IO ()
    receiveProcess r = put $ Just r
    receiveInt :: Int -> StateT (Maybe Process) IO ()
    receiveInt _ =
        get >>= maybe (return ()) (send "int")
    receiveString :: String -> StateT (Maybe Process) IO ()
    receiveString _ =
        get >>= maybe (return ()) (send "string")
    receiveDefault :: StateT (Maybe Process) IO ()
    receiveDefault =
        get >>= maybe (return ()) (send "default")


ooo :: IO ()
ooo = do
    r <- receive
    msg1 <- receiveMatch (==1)
    send (msg1 :: Int) r
    msg2 <- receiveMatch (==2)
    send (msg2 :: Int) r
    msg3 <- receiveMatch (==3)
    send (msg3 :: Int) r

main :: IO ()
main = hspec $ do
    describe "two communicating processes" $ do
        it "exchange ping/pong messages" $ do
            ans <- withProcess "pong" pong $ query Ping
            ans `shouldBe` Pong
        it "monitor setup" $ do
            (lns, mns) <- withProcess "pong" pong $ \s -> do
                monitor s
                atomically $ do
                    lns <- readTVar $ links s
                    mns <- readTVar $ monitors s
                    return (lns, mns)
            map thread lns `shouldBe` []
            my <- myProcess
            map thread mns `shouldBe` [thread my]
        it "monitor one another" $ do
            (sig, tid) <- withProcess "pong" pong $ \s -> do
                monitor s
                stop s
                sig <- receive
                return (sig, thread s)
            sig `shouldBe` tid
        it "dispatch multiple types of message" $ do
            types <- withProcess "dispatch" dispatch $ \d -> do
                me <- myProcess
                send me d
                send "This is a string" d
                send (42 :: Int) d
                send ["List", "of", "strings"] d
                replicateM 3 receive
            types `shouldBe` ["string", "int", "default"]
        it "process messages out of order if needed" $ do
            messages <- withProcess "out-of-order" ooo $ \o -> do
                me <- myProcess
                send me o
                send (2 :: Int) o
                send (3 :: Int) o
                send (1 :: Int) o
                replicateM 3 receive
            messages `shouldBe` ([1, 2, 3] :: [Int])
