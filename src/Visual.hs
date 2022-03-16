{-# LANGUAGE FlexibleInstances #-}

module Visual where

import Control.Monad.Trans.State.Lazy
import Data.Foldable (fold)
import Data.Functor (($>))
import Data.HashMap.Lazy ( HashMap )
import qualified Data.HashMap.Lazy as HML
import Data.List (uncons)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word
import Debug.Trace
import Graphics.Svg
import Numeric (showHex)

data Visual
    = Fix Visual
    | Connect [Visual]
    | Embellish (Maybe String) Visual
    | Group Visual
    | Dot (NonEmpty String)
    deriving stock (Eq, Show)

render :: Visual -> Text
render = \case
    Dot xs -> T.pack $ '.' <$ NE.toList xs
    Connect xs -> T.intercalate "--" $ fmap render xs
    Embellish _ a -> "(" <> render a <> ")"
    Fix a -> "@" <> render a
    Group a -> "{" <> render a <> "}"

data Blobble = Blobble
    { w :: Float -- the width (without 2r)
    , r :: Float -- radius of this bubble
    , x :: Float -- absolute offset x in a larger Blobble
    , y :: Float -- absolute offset y in a larger Blobble
    }
    deriving (Show)

data Color = Color {_r :: Word8, _g :: Word8, _b :: Word8} deriving stock (Eq)

data Env = Env
    { colors :: HashMap String Color
    , idx :: Int
    }

initEnv :: Env
initEnv =
    Env
        { colors = mempty
        , idx = 0
        }

renderSvg :: Blobble -> Visual -> State Env Element
renderSvg blobble@Blobble{..} = \case
    Dot words -> do
        let ys = dotV blobble
            zipped = NE.zip words ys
            elemStates =
                traverse
                    ( \(word, y') -> do
                        s@Env{..} <- get
                        let (newEnv, c) = case HML.lookup word colors of
                                Nothing -> (s{colors = HML.insert word c colors, idx = succ idx}, newColor !! idx)
                                Just c -> (s, c)
                            midX = x + r + w / 2
                            el = circle_ [Cx_ <<- cT midX, Cy_ <<- cT y', R_ <<- "5", Fill_ <<- hex c]
                        put newEnv $> el
                    )
                    zipped
        mconcat . NE.toList <$> elemStates
    Embellish ms a -> do
        s@Env{..} <- get
        let (newEnv, c) = case ms of
                Nothing -> (s, Color 0 0 0)
                Just word -> case HML.lookup word colors of
                                    Nothing -> (s{colors = HML.insert word c colors, idx = succ idx}, newColor !! idx)
                                    Just c' -> (s, c')
    
            rect = rect_ [X_ <<- cT x, Y_ <<- cT y, Width_ <<- cT (r + r + w), Height_ <<- cT (2 * r), Rx_ <<- cT r, Fill_ <<- "none", Stroke_ <<- hex c, Stroke_width_ <<- "3"]
        el <- renderSvg (shrink blobble) a
        put newEnv $> rect <> el
    Group a -> do
        let rect = rect_ [X_ <<- cT x, Y_ <<- cT y, Width_ <<- cT (r + r + w), Height_ <<- cT (2 * r), Rx_ <<- cT r, Fill_ <<- "none", Stroke_ <<- "black", Stroke_width_ <<- "3", Stroke_dasharray_ <<- "4"]
        el <- renderSvg (shrink blobble) a
        pure $ rect <> el
    Fix a -> do
        let arr =
                path_ [D_ <<- mA (x + r + w / 2 + 20) (y + 2 * r) <> lR (-20) 20, Stroke_ <<- "black", Stroke_width_ <<- "3"]
                    <> path_ [D_ <<- mA (x + r + w / 2 + 20) (y + 2 * r) <> lR (-20) (-20), Stroke_ <<- "black", Stroke_width_ <<- "3"]
        el <- renderSvg blobble (Embellish Nothing a)
        el2 <- renderSvg (shrink blobble) a
        pure $ el <> el2 <> arr
    Connect xs -> do
        let blobbles = split (length xs) blobble
            zipped = zip blobbles xs
            lines = connectLines zipped
            res =
                traverse
                    (uncurry renderSvg)
                    zipped
        mconcat . (lines :) <$> res

dotV :: Blobble -> NonEmpty Float -- get y coords
dotV Blobble{..} = 
    let factors = 0 : ([1 .. ] >>= (\i -> [i,i])) :: [Float]
        gameplan = zip (cycle [\f -> r + y + f * 6, \f -> r + y - f * 6]) factors
    in NE.fromList $ (\(f, a) -> f a) <$> gameplan

split :: Int -> Blobble -> [Blobble]
split n parent =
    if n < 2
        then [parent]
        else fmap (go parent n) [1 .. n]
  where
    go :: Blobble -> Int -> Int -> Blobble
    go Blobble{..} total idx =
        let r' = r
            c = if idx == 1 then 0 else r'
            n = fromIntegral total
            w' = (w - 3 * n * r + 3 * r) / n
         in Blobble
                { x = x + ((r' + w' + r' + c) * fromIntegral (pred idx))
                , y = y
                , r = r
                , w = w'
                }

connectLines :: [(Blobble, Visual)] -> Element
connectLines [b1, b2] = path_ [D_ <<- rightEdge mA b1 <> leftEdge lA b2, Stroke_ <<- "black", Stroke_width_ <<- "4"]
connectLines (b1 : xs) =
    case uncons xs of
        Nothing -> mempty
        Just (t, xs') -> connectLines [b1, t] <> connectLines (t : xs')
connectLines _ = mempty

rightEdge :: (Float -> Float -> Text) -> (Blobble, Visual) -> Text
rightEdge svgOp (Blobble{..}, Dot _) = svgOp (x + r + (w / 2)) (y + r)
rightEdge svgOp (Blobble{..}, _) = svgOp (x + w + (2 * r)) (y + r)

leftEdge :: (Float -> Float -> Text) -> (Blobble, Visual) -> Text
leftEdge svgOp (Blobble{..}, Dot _) = svgOp (x + r + (w / 2)) (y + r)
leftEdge svgOp (Blobble{..}, _) = svgOp x (y + r)

cT :: Float -> Text
cT = T.pack . show

shrink :: Blobble -> Blobble
shrink Blobble{..} = Blobble{x = x + 8, y = y + 8, w = w - 1, r = r - 8}

hex :: Color -> Text
hex Color{..} = "#" <> foldMap showHex2 [_r, _g, _b]
  where
    showHex2 :: forall a. (Integral a, Show a) => a -> Text
    showHex2 a = T.pack $ if a < 17 then "0" <> showHex a "" else showHex a ""

newColor :: [Color]
newColor = cycle [Color 0 0 255, Color 255 0 0, Color 0 255 0, Color 255 255 0, Color 0 255 255, Color 255 0 255, Color 0 0 0]