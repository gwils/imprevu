{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE CPP #-}


-- | Evaluation of the events
module Imprevu.Evaluation.EventEval where

import           Control.Applicative
import           Control.Lens
import           Control.Monad
import           Control.Monad.State
import           Control.Monad.Except
import           Data.Either
import           Data.List
import           Data.Maybe
import           Data.Validation
import           Data.Typeable
import           Imprevu.Types
import           Imprevu.Evaluation.Types
import           Imprevu.Evaluation.Utils
import           Prelude                     hiding (log)
import           Safe
#ifdef DEBUG
import           Debug.Trace.Helpers    (traceM)
#else
import           Debug.NoTrace
#endif

-- * Event triggers

-- trigger an event with an event result
triggerEvent :: (Show a, Typeable a, Show e, Typeable e, Eq a) => Signal a e -> e -> EvaluateN n s ()
triggerEvent e dat = do
   evs <- use events
   let evs' = evs                                            -- Sort the event? sortBy (compare `on` _ruleNumber) evs
   let sd = (SignalData e dat)
   eids <- mapM (getUpdatedEventInfo sd) evs'                -- get all the EventInfoNs updated with the field
   traceM $ "triggerEvent called with signal=" ++ (show sd) 
         ++ "\n\tall events=" ++ (show evs) 
         ++ "\n\tresult events=" ++ (show eids)
   events %= union (map fst eids)                            -- store them
   void $ mapM triggerIfComplete eids                        -- trigger the handlers for completed events

-- if the event is complete, trigger its handler
triggerIfComplete :: (EventInfoN n, Maybe SomeData) -> EvaluateN n s ()
triggerIfComplete (ei@(EventInfo en _ h SActive _), Just (SomeData val)) = case cast val of
   Just a -> do
      traceM $ "triggerIfComplete: " ++ (show a)
      eval <- use (evalConf . evalFunc)
      err <- use (evalConf . errorHandler)
      withEvent <- use (evalConf . withEvent)
      void $ withEvent ei $ (eval $ h (en, a)) `catchError` (err en)
   Nothing -> error "Bad trigger data type"
triggerIfComplete _ = return ()


-- get update the EventInfoN updated with the signal data.
-- get the event result if all signals are completed
getUpdatedEventInfo :: SignalData -> EventInfoN n -> EvaluateN n s (EventInfoN n, Maybe SomeData)
getUpdatedEventInfo sd@(SignalData sig _) ei@(EventInfo _ ev _ _ envi) = do
   trs <- getEventResult ev envi
   traceM $ "\ngetUpdatedEventInfo: event results=" ++ (show trs)
   case trs of
      AccFailure rs -> case find (\(sa, (SomeSignal ss)) -> (ss === sig)) rs of -- check if our signal match one of the remaining signals
         Just (sa, _) -> do
            let envi' = SignalOccurence sd (Just sa) : envi
            er <- getEventResult ev envi'                                       -- add our event to the environment and get the result
            case er of
               AccFailure _ -> do
                 traceM $ "\tgetUpdatedEventInfo event to be completed"
                 return (env .~ envi' $ ei, Nothing)                            -- some other signals are left to complete: add ours in the environment
               AccSuccess a -> do
                 traceM $ "\tgetUpdatedEventInfo event completed"
                 return (env .~  [] $ ei, Just $ SomeData a)                    -- event complete: return the final data result
         Nothing -> do
           traceM "\tgetUpdatedEventInfo: no Event matches"
           return (ei, Nothing)                                                 -- our signal does not belong to this event.
      AccSuccess a -> return (env .~  [] $ ei, Just $ SomeData a)


-- * Evaluations

--get the signals left to be completed in an event
getRemainingSignals' :: EventInfoN n -> EvaluateN n s [SomeSignal]
getRemainingSignals' (EventInfo _ e _ _ envi) = do
   tr <- getEventResult e envi
   return $ case tr of
      AccSuccess _ -> []
      AccFailure a -> map snd a

getRemainingSignals :: EventInfoN n -> EvalEnvN n s -> [SomeSignal]
getRemainingSignals ei env = join $ maybeToList $ evalState (runEvalError (getRemainingSignals' ei)) env


-- compute the result of an event, using the signals that already fired.
-- in the case the event cannot be computed because some signals results are pending, return that list instead.
getEventResult :: EventM n a -> [SignalOccurence] -> EvaluateN n s (AccValidation [(SignalAddress, SomeSignal)] a)
getEventResult e frs = getEventResult' e frs []

-- compute the result of an event given an environment. The third argument is used to know where we are in the event tree.
getEventResult' :: EventM n a -> [SignalOccurence] -> SignalAddress -> EvaluateN n s (AccValidation [(SignalAddress, SomeSignal)] a)
getEventResult' (PureEvent a)   _   _  = return $ AccSuccess a
getEventResult'  EmptyEvent     _   _  = return $ AccFailure []
getEventResult' (SumEvent a b)  ers fa = liftM2 (<|>) (getEventResult' a ers (L:fa)) (getEventResult' b ers (R:fa))
getEventResult' (AppEvent f b)  ers fa = liftM2 (<*>) (getEventResult' f ers (L:fa)) (getEventResult' b ers (R:fa))
getEventResult' (LiftEvent a)   _   _  = do
   eval <- use (evalConf . evalFunc)
   AccSuccess <$> eval a

getEventResult' (BindEvent a f) ers fa = do
   er <- getEventResult' a ers (L:fa)
   case er of
      AccSuccess a' -> getEventResult' (f a') ers (R:fa)
      AccFailure bs -> return $ AccFailure bs

getEventResult' (SignalEvent a) ers fa = return $ case lookupSignal a fa ers of
   Just r  -> AccSuccess r
   Nothing -> AccFailure [(fa, SomeSignal a)]

getEventResult' (ShortcutEvents es f) ers fa = do
  ers' <- mapM (\e -> getEventResult' e ers (R:fa)) es               -- get the result for each event in the list
  traceM $ "getEventResult" ++ (show $ f (toMaybe <$> ers'))
  return $ if f (toMaybe <$> ers')                                   -- apply f to the event results that we already have
     then AccSuccess $ toMaybe <$> ers'                              -- if the result is true, we are done. Return the list of maybe results
     else AccFailure $ join $ lefts $ toEither <$> ers'              -- otherwise, return the list of remaining fields to complete from each event


-- find a signal occurence in an environment
lookupSignal :: (Typeable a, Typeable s, Eq s) => Signal s a -> SignalAddress -> [SignalOccurence] -> Maybe a
lookupSignal s sa envi = headMay $ mapMaybe (getSignalData s sa) envi

--get the signal data from the signal occurence
getSignalData :: (Typeable a, Typeable s, Eq s) => Signal s a -> SignalAddress -> SignalOccurence -> Maybe a
getSignalData s sa (SignalOccurence (SignalData s' res) sa') = do
  res' <- cast res
  --both the signals and the addresses must match
  --the addresses need to be compared too because it's possible to build an event with several identical signals.
  if (isJust sa')
    then if (fromJust sa' == sa) && (s === s') then Just res' else Nothing
    else if                         (s === s') then Just res' else Nothing

runEvalError :: EvaluateN n s a -> State (EvalEnvN n s) (Maybe a)
runEvalError egs = do
   e <- runExceptT egs
   log <- use (evalConf . errorHandler)
   case e of
      Right a -> return $ Just a
      Left e' -> do
         traceM $ "Error: " ++ e'
         void $ runExceptT $ log 0 $ "Error: " ++ e'
         return Nothing

runEvaluate :: EvaluateN n s a -> EvalEnvN n s -> Maybe a
runEvaluate ev ee = evalState (runEvalError ev) ee

--TODO simplify
execSignals :: (Show a, Show e, Typeable e, Eq e, Show d, Typeable d, Eq d) => n a -> [(Signal e d, d)] -> EvalEnvN n s -> s
execSignals r sds evalEnv = _evalEnv $ runIdentity $ flip execStateT evalEnv $ do
   res <- runExceptT $ do
      let eval = _evalFunc $ _evalConf evalEnv
      eval r
      mapM_ (\(f,d) -> triggerEvent f d) sds
   case res of
      Right a -> return a
      Left s -> error $ "error occured: " ++ s


