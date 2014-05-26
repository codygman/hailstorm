module Hailstorm.Negotiator
( runNegotiator
, spoutStatePipe
) where

import Control.Applicative
import Control.Concurrent hiding (yield)
import Control.Exception
import Control.Monad
import Data.IORef
import Data.Maybe
import Pipes
import Hailstorm.Clock
import Hailstorm.MasterState
import Hailstorm.Error
import Hailstorm.Payload
import Hailstorm.Processor
import Hailstorm.Topology
import Hailstorm.ZKCluster
import qualified Data.Foldable as Foldable
import qualified Data.Map as Map
import qualified Database.Zookeeper as ZK

runNegotiator :: Topology t => ZKOptions -> t -> IO ()
runNegotiator zkOpts topology = do
    fullChildrenThreadId <- newIORef (Nothing :: Maybe ThreadId)
    registerProcessor zkOpts ("negotiator", 0) UnspecifiedState $ \zk ->
        forceEitherIO
            (DuplicateNegotiatorError "Could not set state: duplicate process?")
            (debugSetMasterState zk Initialization) >>
              watchLoop zk fullChildrenThreadId
    throw $ ZookeeperConnectionError "Unable to register Negotiator"
  where
    fullThread zk = forever $ do
        waitUntilSnapshotsComplete zk topology
        threadDelay $ 1000 * 1000 * 5
        nextSnapshotClock <- negotiateSnapshot zk topology
        void <$> forceEitherIO UnknownWorkerException $
            debugSetMasterState zk $ GreenLight nextSnapshotClock

    watchLoop zk fullThreadId = watchProcessors zk $ \childrenEither ->
        case childrenEither of
            Left e -> throw $ wrapInHSError e UnexpectedZookeeperError
            Right children -> do
                killFromRef fullThreadId

                putStrLn $ "Processors changed: " ++ show children
                let expectedRegistrations = numProcessors topology + 1

                if length children < expectedRegistrations
                    then do
                        putStrLn "Not enough children"
                        void <$> forceEitherIO UnexpectedZookeeperError $
                            debugSetMasterState zk Unavailable
                    else do
                        tid <- forkOS $ fullThread zk
                        writeIORef fullThreadId $ Just tid

spoutStatePipe :: ZK.Zookeeper
               -> ProcessorId
               -> MVar MasterState
               -> Pipe (Payload k v) (Payload k v) IO ()
spoutStatePipe zk spoutId stateMVar = forever $ do
    ms <- lift $ readMVar stateMVar
    case ms of
        GreenLight _ -> passOn
        SpoutPause ->  do
            void <$> lift $ forceEitherIO UnknownWorkerException
                (setProcessorState zk spoutId $ SpoutPaused "fun" 0)
            lift $ pauseUntilGreen stateMVar
            void <$> lift $ forceEitherIO UnknownWorkerException
                (setProcessorState zk spoutId SpoutRunning)
        _ -> do
            lift $ putStrLn $
                "Spout waiting for green light (state: " ++ show ms ++ ")"
            lift $ threadDelay $ 1000 * 1000 * 10
  where passOn = await >>= yield

pauseUntilGreen :: MVar MasterState -> IO ()
pauseUntilGreen stateMVar = do
    ms <- readMVar stateMVar
    case ms of
        GreenLight _ -> return ()
        _ -> threadDelay (1000 * 1000) >> pauseUntilGreen stateMVar

debugSetMasterState :: ZK.Zookeeper
                    -> MasterState
                    -> IO (Either ZK.ZKError ZK.Stat)
debugSetMasterState zk ms = do
    r <- setMasterState zk ms
    putStrLn $ "Master state set to " ++ show ms
    return r

killFromRef :: IORef (Maybe ThreadId) -> IO ()
killFromRef ioRef = do
    mt <- readIORef ioRef
    Foldable.forM_ mt killThread

waitUntilSnapshotsComplete :: Topology t => ZK.Zookeeper -> t -> IO ()
waitUntilSnapshotsComplete _ _ = return ()

negotiateSnapshot :: (Topology t) => ZK.Zookeeper -> t -> IO Clock
negotiateSnapshot zk t = do
    void <$> forceEitherIO UnknownWorkerException $
        debugSetMasterState zk SpoutPause
    offsetsAndPartitions <- untilSpoutsPaused
    return $ Clock (Map.fromList offsetsAndPartitions)

    where untilSpoutsPaused = do
            stateMap <- forceEitherIO UnknownWorkerException $
                getAllProcessorStates zk
            let spoutStates = map (\k -> fromJust $ Map.lookup k stateMap)
                    (spoutIds t)
                spoutsPaused = [(p,o) | (SpoutPaused p o) <- spoutStates]
            if length spoutsPaused == length spoutStates
                then return spoutsPaused
                else untilSpoutsPaused
