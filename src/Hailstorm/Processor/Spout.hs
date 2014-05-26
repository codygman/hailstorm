module Hailstorm.Processor.Spout
( runSpout
) where

import Control.Applicative
import Control.Concurrent hiding (yield)
import Control.Exception
import Control.Monad
import Data.ByteString.Char8 ()
import Hailstorm.UserFormula
import Hailstorm.Error
import Hailstorm.InputSource
import Hailstorm.MasterState
import Hailstorm.Payload
import Hailstorm.Processor
import Hailstorm.Processor.Pool
import Hailstorm.Topology
import Hailstorm.ZKCluster
import Pipes
import qualified Database.Zookeeper as ZK

-- | Start processing with a spout.
runSpout :: (Topology t, InputSource s)
         => ZKOptions
         -> ProcessorName
         -> Partition
         -> t
         -> s
         -> UserFormula k v
         -> IO ()
runSpout zkOpts pName partition topology inputSource uFormula = do
    index <- partitionIndex inputSource partition
    let spoutId = (pName, index)
    registerProcessor zkOpts spoutId SpoutRunning $ \zk ->
        injectMasterState zk (pipeThread zk spoutId)
    throw $ ZookeeperConnectionError $ "Unable to register spout " ++ pName
  where
    pipeThread zk spoutId stateMVar =
      let downstream = downstreamPoolConsumer (fst spoutId) topology uFormula
          producer = payloadProducer uFormula $
              partitionProducer inputSource partition 0
      in runEffect $
          producer >-> spoutStatePipe zk spoutId stateMVar >-> downstream

spoutStatePipe :: ZK.Zookeeper
               -> ProcessorId
               -> MVar MasterState
               -> Pipe (Payload k v) (Payload k v) IO ()
spoutStatePipe zk spoutId stateMVar = forever $ do
    ms <- lift $ readMVar stateMVar
    case ms of
        Flowing _ -> passOn
        Blocked ->  do
            void <$> lift $ forceEitherIO UnknownWorkerException
                (setProcessorState zk spoutId $ SpoutPaused "fun" 0)
            lift $ pauseUntilFlowing stateMVar
            void <$> lift $ forceEitherIO UnknownWorkerException
                (setProcessorState zk spoutId SpoutRunning)
        _ -> do
            lift $ putStrLn $
                "Spout waiting for open valve (state: " ++ show ms ++ ")"
            lift $ threadDelay $ 1000 * 1000 * 10
  where passOn = await >>= yield

pauseUntilFlowing :: MVar MasterState -> IO ()
pauseUntilFlowing stateMVar = do
    ms <- readMVar stateMVar
    case ms of
        Flowing _ -> return ()
        _ -> threadDelay (1000 * 1000) >> pauseUntilFlowing stateMVar

