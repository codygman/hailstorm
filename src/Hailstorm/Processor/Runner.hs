{-# LANGUAGE OverloadedStrings #-}

module Hailstorm.Processor.Runner
( runSpoutFromProducer
, runSink
, runNegotiator
) where

import Control.Exception
import Control.Monad
import Data.ByteString.Char8 ()
import Data.List.Split
import Hailstorm.Clock
import Hailstorm.Error
import Hailstorm.Payload
import Hailstorm.Topology
import Hailstorm.UserFormula
import Hailstorm.ZKCluster
import Network.Simple.TCP
import Network.Socket(socketToHandle)
import Pipes
import System.IO
import qualified Data.Map as Map

runSpoutFromProducer :: (Show k, Show v, Topology t)
                     => ZKOptions
                     -> String
                     -> t
                     -> UserFormula k v
                     -> Producer (Payload k v) IO ()
                     -> IO ()
runSpoutFromProducer zkOpts spoutId  topology uf producer = do
    registerProcessor zkOpts spoutId $ (\_ -> do
            let downstream = downstreamConsumer spoutId topology uf
            runEffect $ producer >-> downstream
        )

    throw $ ZookeeperConnectionError "Spout zookeeper registration terminated unexpectedly"

runSink :: (Show k, Show v, Read k, Read v, Topology t)
        => ZKOptions
        -> (String, Int)
        -> t
        -> UserFormula k v
        -> IO ()
runSink opts (processorName, offset) topology uformula = do
    let (_, port) = addressFor topology (processorName, offset)
        accepted socket = let sp = socketProducer uformula socket
                              fc = formulaConsumer uformula
                          in runEffect $ sp >-> fc
    registerProcessor opts processorName $ \_ ->
        serve HostAny port $ \(s, _) -> accepted s

    throw $ ZookeeperConnectionError "Sink zookeeper registration terminated unexpectedly"

runNegotiator :: (Topology t) => ZKOptions -> t -> IO ()
runNegotiator zkOpts topology = do
    registerProcessor zkOpts "negotiator" $ \zk ->
        (forceEitherIO (DuplicateNegotiatorError "Could not set state, probable duplicate process") 
            (createMasterState zk Initialization)) >> watchLoop zk

    throw $ ZookeeperConnectionError "Negotiator zookeeper registration terminated unexpectedly"

    where watchLoop zk = childrenWatchLoop zk "/living_processors" $ \children -> do
            putStrLn $ "Children changed to " ++ (show children)
            let expectedRegistrations = numProcessors topology + 1

            if length children < expectedRegistrations then putStrLn $ "Not enough children yet"
            else forceEitherIO UnknownWorkerException (setMasterState zk GreenLight)  
                    >> (putStrLn $ "Master state set to green light")

formulaConsumer :: UserFormula k v -> Consumer (Payload k v) IO ()
formulaConsumer uf = forever $ do
    payload <- await
    lift $ outputFn uf (payloadTuple payload)

socketProducer :: (Read k, Read v)
               => UserFormula k v
               -> Socket
               -> Producer (Payload k v) IO ()
socketProducer uf s = do
    h <- lift (socketToHandle s ReadMode)
    lift $ hSetBuffering h LineBuffering
    producerInternal h
  where
    producerInternal h = do
        t <- lift $ hGetLine h
        let [sTuple, sClock] = splitOn "\1" t
            tuple = deserialize uf sTuple
            clock = read sClock :: Clock
        yield (Payload tuple clock)
        producerInternal h

poolConnect :: (String, String) -> Map.Map (String, String) Handle -> IO Handle
poolConnect (host, port) m = case Map.lookup (host, port) m of
    Just so -> return so
    Nothing -> connect host port (\(s, _) -> socketToHandle s WriteMode)

downstreamConsumer :: (Show k, Show v, Topology t)
                   => String
                   -> t
                   -> UserFormula k v
                   -> Consumer (Payload k v) IO ()
downstreamConsumer processorId topology uf = dcInternal Map.empty
    where dcInternal connectionPool = do
            payload <- await
            let sendAddresses = downstreamAddresses topology processorId payload
                addressToHandle (host, port) = do
                    h <- lift $ poolConnect (host, port) connectionPool
                    lift $ hPutStrLn h (serialize uf (payloadTuple payload) ++
                      "\1" ++ show (payloadClock payload))
                    return ((host, port), h)
            newHandles <- mapM addressToHandle sendAddresses
            dcInternal $ Map.union (Map.fromList newHandles) connectionPool
