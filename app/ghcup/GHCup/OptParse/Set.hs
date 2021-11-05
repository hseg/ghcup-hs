{-# LANGUAGE CPP               #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes #-}

module GHCup.OptParse.Set where




import           GHCup.OptParse.Common

import           GHCup
import           GHCup.Errors
import           GHCup.Types
import           GHCup.Logger
import           GHCup.QQ.String

#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           Data.Either
import           Data.Functor
import           Data.Maybe
import           Data.Versions           hiding ( str )
import           GHC.Unicode
import           Haskus.Utils.Variant.Excepts
import           Options.Applicative     hiding ( style )
import           Options.Applicative.Help.Pretty ( text )
import           Prelude                 hiding ( appendFile )
import           System.Exit
import           Text.PrettyPrint.HughesPJClass ( prettyShow )

import qualified Data.Text                     as T
import Data.Bifunctor (second)
import Control.Exception.Safe (MonadMask)
import GHCup.Types.Optics




    ----------------
    --[ Commands ]--
    ----------------


data SetCommand = SetGHC SetOptions
                | SetCabal SetOptions
                | SetHLS SetOptions
                | SetStack SetOptions




    ---------------
    --[ Options ]--
    ---------------


data SetOptions = SetOptions
  { sToolVer :: SetToolVersion
  }




    ---------------
    --[ Parsers ]--
    ---------------

          
setParser :: Parser (Either SetCommand SetOptions)
setParser =
  (Left <$> subparser
      (  command
          "ghc"
          (   SetGHC
          <$> info
                (setOpts (Just GHC) <**> helper)
                (  progDesc "Set GHC version"
                <> footerDoc (Just $ text setGHCFooter)
                )
          )
      <> command
           "cabal"
           (   SetCabal
           <$> info
                 (setOpts (Just Cabal) <**> helper)
                 (  progDesc "Set Cabal version"
                 <> footerDoc (Just $ text setCabalFooter)
                 )
           )
      <> command
           "hls"
           (   SetHLS
           <$> info
                 (setOpts (Just HLS) <**> helper)
                 (  progDesc "Set haskell-language-server version"
                 <> footerDoc (Just $ text setHLSFooter)
                 )
           )
      <> command
           "stack"
           (   SetStack
           <$> info
                 (setOpts (Just Stack) <**> helper)
                 (  progDesc "Set stack version"
                 <> footerDoc (Just $ text setStackFooter)
                 )
           )
      )
    )
    <|> (Right <$> setOpts Nothing)
 where
  setGHCFooter :: String
  setGHCFooter = [s|Discussion:
    Sets the the current GHC version by creating non-versioned
    symlinks for all ghc binaries of the specified version in
    "~/.ghcup/bin/<binary>".|]

  setCabalFooter :: String
  setCabalFooter = [s|Discussion:
    Sets the the current Cabal version.|]

  setStackFooter :: String
  setStackFooter = [s|Discussion:
    Sets the the current Stack version.|]

  setHLSFooter :: String
  setHLSFooter = [s|Discussion:
    Sets the the current haskell-language-server version.|]


setOpts :: Maybe Tool -> Parser SetOptions
setOpts tool = SetOptions <$>
    (fromMaybe SetRecommended <$>
      optional (setVersionArgument (Just ListInstalled) tool))

setVersionArgument :: Maybe ListCriteria -> Maybe Tool -> Parser SetToolVersion
setVersionArgument criteria tool =
  argument (eitherReader setEither)
    (metavar "VERSION|TAG|next"
    <> completer (tagCompleter (fromMaybe GHC tool) ["next"])
    <> foldMap (completer . versionCompleter criteria) tool)
 where
  setEither s' =
        parseSet s'
    <|> second SetToolTag (tagEither s')
    <|> second SetToolVersion (tVersionEither s')
  parseSet s' = case fmap toLower s' of
                  "next" -> Right SetNext
                  other  -> Left $ "Unknown tag/version " <> other




    --------------
    --[ Footer ]--
    --------------


setFooter :: String
setFooter = [s|Discussion:
  Sets the currently active GHC or cabal version. When no command is given,
  defaults to setting GHC with the specified version/tag (if no tag
  is given, sets GHC to 'recommended' version).
  It is recommended to always specify a subcommand (ghc/cabal/hls/stack).|]



    ---------------------------
    --[ Effect interpreters ]--
    ---------------------------


type SetGHCEffects = '[ FileDoesNotExistError
                   , NotInstalled
                   , TagNotFound
                   , NextVerNotFound
                   , NoToolVersionSet]

runSetGHC :: (ReaderT env m (VEither SetGHCEffects a) -> m (VEither SetGHCEffects a))
          -> Excepts SetGHCEffects (ReaderT env m) a
          -> m (VEither SetGHCEffects a)
runSetGHC runAppState =
    runAppState
    . runE
      @SetGHCEffects


type SetCabalEffects = '[ NotInstalled
                        , TagNotFound
                        , NextVerNotFound
                        , NoToolVersionSet]

runSetCabal :: (ReaderT env m (VEither SetCabalEffects a) -> m (VEither SetCabalEffects a))
            -> Excepts SetCabalEffects (ReaderT env m) a
            -> m (VEither SetCabalEffects a)
runSetCabal runAppState =
    runAppState
    . runE
      @SetCabalEffects


type SetHLSEffects = '[ NotInstalled
                      , TagNotFound
                      , NextVerNotFound
                      , NoToolVersionSet]

runSetHLS :: (ReaderT env m (VEither SetHLSEffects a) -> m (VEither SetHLSEffects a))
          -> Excepts SetHLSEffects (ReaderT env m) a
          -> m (VEither SetHLSEffects a)
runSetHLS runAppState =
    runAppState
    . runE
      @SetHLSEffects


type SetStackEffects = '[ NotInstalled
                        , TagNotFound
                        , NextVerNotFound
                        , NoToolVersionSet]

runSetStack :: (ReaderT env m (VEither SetStackEffects a) -> m (VEither SetStackEffects a))
            -> Excepts SetStackEffects (ReaderT env m) a
            -> m (VEither SetStackEffects a)
runSetStack runAppState =
    runAppState
    . runE
      @SetStackEffects



    -------------------
    --[ Entrypoints ]--
    -------------------


set :: forall m env.
       ( Monad m
       , MonadMask m
       , MonadUnliftIO m
       , MonadFail m
       , HasDirs env
       , HasLog env
       )
    => Either SetCommand SetOptions
    -> (forall eff . ReaderT AppState m (VEither eff GHCTargetVersion)
        -> m (VEither eff GHCTargetVersion))
    -> (forall eff. ReaderT env m (VEither eff GHCTargetVersion)
        -> m (VEither eff GHCTargetVersion))
    -> (ReaderT LeanAppState m () -> m ())
    -> m ExitCode
set setCommand runAppState runLeanAppState runLogger = case setCommand of
  (Right sopts) -> do
    runLogger (logWarn "This is an old-style command for setting GHC. Use 'ghcup set ghc' instead.")
    setGHC' sopts
  (Left (SetGHC sopts)) -> setGHC' sopts
  (Left (SetCabal sopts)) -> setCabal' sopts
  (Left (SetHLS sopts)) -> setHLS' sopts
  (Left (SetStack sopts)) -> setStack' sopts

 where
  setGHC' :: SetOptions
          -> m ExitCode
  setGHC' SetOptions{ sToolVer } =
    case sToolVer of
      (SetToolVersion v) -> runSetGHC runLeanAppState (liftE $ setGHC v SetGHCOnly >> pure v)
      _ -> runSetGHC runAppState (do
          v <- liftE $ fst <$> fromVersion' sToolVer GHC
          liftE $ setGHC v SetGHCOnly
        )
      >>= \case
            VRight GHCTargetVersion{..} -> do
              runLogger
                $ logInfo $
                    "GHC " <> prettyVer _tvVersion <> " successfully set as default version" <> maybe "" (" for cross target " <>) _tvTarget
              pure ExitSuccess
            VLeft e -> do
              runLogger $ logError $ T.pack $ prettyShow e
              pure $ ExitFailure 5


  setCabal' :: SetOptions
            -> m ExitCode
  setCabal' SetOptions{ sToolVer } =
    case sToolVer of
      (SetToolVersion v) -> runSetCabal runLeanAppState (liftE $ setCabal (_tvVersion v) >> pure v)
      _ -> runSetCabal runAppState (do
          v <- liftE $ fst <$> fromVersion' sToolVer Cabal
          liftE $ setCabal (_tvVersion v)
          pure v
        )
      >>= \case
            VRight GHCTargetVersion{..} -> do
              runLogger
                $ logInfo $
                    "Cabal " <> prettyVer _tvVersion <> " successfully set as default version"
              pure ExitSuccess
            VLeft  e -> do
              runLogger $ logError $ T.pack $ prettyShow e
              pure $ ExitFailure 14

  setHLS' :: SetOptions
          -> m ExitCode
  setHLS' SetOptions{ sToolVer } =
    case sToolVer of
      (SetToolVersion v) -> runSetHLS runLeanAppState (liftE $ setHLS (_tvVersion v) >> pure v)
      _ -> runSetHLS runAppState (do
          v <- liftE $ fst <$> fromVersion' sToolVer HLS
          liftE $ setHLS (_tvVersion v)
          pure v
        )
      >>= \case
            VRight GHCTargetVersion{..} -> do
              runLogger
                $ logInfo $
                    "HLS " <> prettyVer _tvVersion <> " successfully set as default version"
              pure ExitSuccess
            VLeft  e -> do
              runLogger $ logError $ T.pack $ prettyShow e
              pure $ ExitFailure 14


  setStack' :: SetOptions
            -> m ExitCode
  setStack' SetOptions{ sToolVer } =
    case sToolVer of
      (SetToolVersion v) -> runSetStack runLeanAppState (liftE $ setStack (_tvVersion v) >> pure v)
      _ -> runSetStack runAppState (do
            v <- liftE $ fst <$> fromVersion' sToolVer Stack
            liftE $ setStack (_tvVersion v)
            pure v
          )
      >>= \case
            VRight GHCTargetVersion{..} -> do
              runLogger
                $ logInfo $
                    "Stack " <> prettyVer _tvVersion <> " successfully set as default version"
              pure ExitSuccess
            VLeft  e -> do
              runLogger $ logError $ T.pack $ prettyShow e
              pure $ ExitFailure 14
