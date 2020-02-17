module Main where

import Control.Arrow ((&&&))
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Extra hiding (loop)
import Control.Monad.IO.Class
import Control.Monad.Random
import Control.Monad.State.Strict
import Data.Char
import Data.IORef
import Data.List
import Data.List.Extra
import Game.Chess
import Game.Chess.Polyglot.Book (PolyglotBook, defaultBook, readPolyglotFile, bookPlies, bookPly)
import Game.Chess.UCI hiding (outputStrLn)
import System.Console.Haskeline hiding (catch, handle)
import System.Exit
import System.Environment
import Time.Units

data S = S {
  engine :: Engine
, mover :: Maybe ThreadId
, book :: PolyglotBook
, hintRef :: IORef (Maybe Ply)
}

main :: IO ()
main = getArgs >>= \case
  [] -> do
    putStrLn "Please specify a UCI engine at the command line"
    exitWith $ ExitFailure 1
  (cmd:args) -> start cmd args >>= \case
    Nothing -> do
      putStrLn "Unable to initialise engine, maybe it doesn't speak UCI?"
      exitWith $ ExitFailure 2
    Just e -> do
      s <- S e Nothing defaultBook <$> newIORef Nothing
      runInputT (setComplete (completeSAN e) defaultSettings) chessIO `evalStateT` s
      exitSuccess

completeSAN :: MonadIO m => Engine -> CompletionFunc m
completeSAN e = completeWord Nothing "" $ \w ->
  fmap (map mkCompletion . filter (w `isPrefixOf`)) $ do
    pos <- currentPosition e
    pure $ unsafeToSAN pos <$> legalPlies pos
 where
  mkCompletion s = (simpleCompletion s) { isFinished = False }

chessIO :: InputT (StateT S IO) ()
chessIO = do
  outputStr . unlines $ [
      ""
    , "Enter a FEN string to set the starting position."
    , "To make a move, enter a SAN or UCI string."
    , "Type \"hint\" to ask for a suggestion."
    , "Type \"pass\" to let the engine make the next move, \"stop\" to end the search."
    , "Empty input will redraw the board."
    , "Hit Ctrl-D to quit."
    , ""
    ]
  outputBoard
  loop
  lift (gets engine) >>= void . quit

midgame :: InputT (StateT S IO) ()
midgame = do
  e <- lift $ gets engine
  b <- lift $ gets book
  pos <- currentPosition e
  case bookPly b pos of
    Just r -> do
      pl <- liftIO . evalRandIO $ r
      addPly e pl
      (bmc, _) <- search e [movetime (ms 100)]
      liftIO $ do
        (bm, _) <- atomically . readTChan $ bmc
        addPly e bm
      midgame
    Nothing -> outputBoard

outputBoard :: InputT (StateT S IO) ()
outputBoard = do
  e <- lift $ gets engine
  liftIO $ do
    pos <- currentPosition e
    printBoard putStrLn pos

loop :: InputT (StateT S IO) ()
loop = do
  e <- lift $ gets engine
  getInputLine "> " >>= \case
    Nothing -> pure ()
    Just input
      | null input -> outputBoard *> loop
      | Just position <- fromFEN input -> do
        void $ setPosition e position
        outputBoard
        loop
      | "hint" == input -> do
        lift (gets hintRef) >>= liftIO . readIORef >>= \case
          Just hint -> do
            pos <- currentPosition e
            outputStrLn $ "Try " <> toSAN pos hint
          Nothing -> outputStrLn "Sorry, no hint available"
        loop
      | "pass" == input -> do
        unlessM (searching e) $ do
          (bmc, _) <- search e [movetime (sec 2)]
          hr <- lift $ gets hintRef
          externalPrint <- getExternalPrint
          tid <- liftIO . forkIO $ doBestMove externalPrint hr bmc e
          lift $ modify' $ \s -> s { mover = Just tid }
        loop
      | input `elem` ["analyze", "analyse"] -> do
        unlessM (searching e) $ do
          pos <- currentPosition e
          (bmc, ic) <- search e [infinite]
          externalPrint <- getExternalPrint
          itid <- liftIO . forkIO . forever $ do
            info <- atomically . readTChan $ ic
            case (find isScore &&& find isPV) info of
              (Just (Score s Nothing), Just (PV pv)) ->
                externalPrint $ show s <> ": " <> varToString pos pv
              _ -> pure ()
          tid <- liftIO . forkIO $ do
            (bm, ponder) <- atomically . readTChan $ bmc
            killThread itid
            pos <- currentPosition e
            externalPrint $ "Best move: " <> toSAN pos bm
          lift $ modify' $ \s -> s { mover = Just tid }
        loop
      | "stop" == input -> do
        stop e
        loop
      | ["polyglot", file] <- words input -> do
        b <- liftIO $ readPolyglotFile file
        lift $ modify $ \x -> x { book = b }
        loop
      | "book" == input -> do
        b <- lift $ gets book
        pos <- currentPosition e
        let plies = bookPlies b pos
        if not . null $ plies
          then do
            addPly e (head plies)
            outputBoard
            (bmc, _) <- search e [movetime (sec 1)]
            hr <- lift $ gets hintRef
            externalPrint <- getExternalPrint
            tid <- liftIO . forkIO $ doBestMove externalPrint hr bmc e
            lift $ modify' $ \s -> s { mover = Just tid }
          else pure ()
        loop
      | "midgame" == input -> do
        void $ setPosition e startpos
        midgame
        loop
      | otherwise -> do
        pos <- currentPosition e
        case parseMove pos input of
          Left err -> outputStrLn err
          Right m -> ifM (searching e) (outputStrLn "Not your move") $ do
            addPly e m
            outputBoard
            (bmc, _) <- search e [movetime (sec 1)]
            hr <- lift $ gets hintRef
            externalPrint <- getExternalPrint
            tid <- liftIO . forkIO $ doBestMove externalPrint hr bmc e
            lift $ modify' $ \s -> s { mover = Just tid }
        loop

varToString :: Position -> [Ply] -> String
varToString _ [] = ""
varToString pos ms
  | color pos == Black && length ms == 1
  = show (moveNumber pos) <> "..." <> toSAN pos (head ms)
  | color pos == Black
  = show (moveNumber pos) <> "..." <> toSAN pos (head ms) <> " " <> fromWhite (doPly pos (head ms)) (tail ms)
  | otherwise
  = fromWhite pos ms
 where
  fromWhite pos = unwords . concat
                . zipWith f [moveNumber pos ..] . chunksOf 2 . snd
                . mapAccumL (curry (uncurry doPly &&& uncurry toSAN)) pos
  f n (x:xs) = (show n <> "." <> x):xs

parseMove :: Position -> String -> Either String Ply
parseMove pos s = case fromUCI pos s of
  Just m -> pure m
  Nothing -> fromSAN pos s

printBoard :: (String -> IO ()) -> Position -> IO ()
printBoard externalPrint pos = externalPrint . init . unlines $
  (map . map) pc (reverse $ chunksOf 8 [A1 .. H8])
 where
  pc sq = (if isDark sq then toUpper else toLower) $ case pieceAt pos sq of
    Just (White, Pawn)   -> 'P'
    Just (White, Knight) -> 'N'
    Just (White, Bishop) -> 'B'
    Just (White, Rook)   -> 'R'
    Just (White, Queen)  -> 'Q'
    Just (White, King)   -> 'K'
    Just (Black, Pawn)   -> 'X'
    Just (Black, Knight) -> 'S'
    Just (Black, Bishop) -> 'L'
    Just (Black, Rook)   -> 'T'
    Just (Black, Queen)  -> 'D'
    Just (Black, King)   -> 'J'
    Nothing | isDark sq -> '.'
            | otherwise -> ' '

doBestMove :: (String -> IO ())
           -> IORef (Maybe Ply)
           -> TChan (Ply, Maybe Ply)
           -> Engine
           -> IO ()
doBestMove externalPrint hintRef bmc e = do
  (bm, ponder) <- atomically . readTChan $ bmc
  pos <- currentPosition e
  externalPrint $ "< " <> toSAN pos bm
  addPly e bm
  currentPosition e >>= printBoard externalPrint
  writeIORef hintRef ponder

printPV :: (String -> IO ()) -> TChan [Info] -> IO ()
printPV externalPrint ic = forever $ do
  info <- atomically . readTChan $ ic
  case find isPV info of
    Just pv -> externalPrint $ show pv
    Nothing -> pure ()

isPV, isScore :: Info -> Bool
isPV PV{}       = True
isPV _          = False
isScore Score{} = True
isScore _       = False
