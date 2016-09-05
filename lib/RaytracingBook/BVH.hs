{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module RaytracingBook.BVH where

import RaytracingBook.Hitable
import RaytracingBook.Ray

import Control.Lens
import Control.Monad
import Control.Monad.ST
import Control.Monad.Zip
import Data.Ord
import Linear
import Linear.Affine
import qualified Data.Vector as V
import qualified Data.Vector.Algorithms.Intro as VAI

class Hitable f a => BoundedHitable f a where
    -- | Get the bounding box
    -- In the result, the first component contains the smaller values
    boundingBox :: a -> (Point V3 f, Point V3 f)
    centroid :: a -> Point V3 f
    {-# INLINE centroid #-}
    default centroid :: Fractional f => a -> Point V3 f
    centroid x = (\(l,h) -> l+h/2) $ boundingBox x

data BoundedHitableItem f =
    BoundedHitableItem
    { bhi_hitFun :: !(Ray f -> f -> f -> Maybe (HitRecord f))
    , bhi_boundingBox :: !(Point V3 f, Point V3 f)
    , bhi_centroid :: !(Point V3 f)
    }

instance Hitable f (BoundedHitableItem f) where
    hit = bhi_hitFun
    {-# INLINE hit #-}

instance BoundedHitable f (BoundedHitableItem f) where
    boundingBox = bhi_boundingBox
    {-# INLINE boundingBox #-}
    centroid = bhi_centroid
    {-# INLINE centroid #-}

getBoundedHitableItem :: BoundedHitable f a => a -> BoundedHitableItem f
getBoundedHitableItem x =
    BoundedHitableItem
    { bhi_hitFun = hit x
    , bhi_boundingBox = boundingBox x
    , bhi_centroid = centroid x
    }

data BoundingBox f =
    BoundingBox !(Point V3 f) !(Point V3 f) !(V.Vector (BoundedHitableItem f))

instance (Ord f, Fractional f) => Hitable f (BoundingBox f) where
    hit (BoundingBox l h items) ray t_min t_max = do
        let t_x1 = (l^._x - ray^.ray_origin._x) / ray^.ray_direction._x
            t_x2 = (h^._x - ray^.ray_origin._x) / ray^.ray_direction._x
            t_min1 = max t_min (min t_x1 t_x2)
            t_max1 = min t_max (max t_x1 t_x2)
            t_y1 = (l^._y - ray^.ray_origin._y) / ray^.ray_direction._y
            t_y2 = (h^._y - ray^.ray_origin._y) / ray^.ray_direction._y
            t_min2 = max t_min1 (min t_y1 t_y2)
            t_max2 = min t_max1 (max t_y1 t_y2)
            t_z1 = (l^._z - ray^.ray_origin._z) / ray^.ray_direction._z
            t_z2 = (h^._z - ray^.ray_origin._z) / ray^.ray_direction._z
            t_min3 = max t_min2 (min t_z1 t_z2)
            t_max3 = min t_max2 (max t_z1 t_z2)
        guard (t_max3 >= t_min3)
        snd $ V.foldl' (merge t_min3) (t_max3, Nothing) items
      where
        merge :: f -> (f, Maybe (HitRecord f)) -> BoundedHitableItem f -> (f, Maybe (HitRecord f))
        merge t_min (t_max, mClosest) item = do
            case hit item ray t_min t_max `mplus` mClosest of
              Just closest -> (closest^.hit_t, Just closest)
              Nothing -> (t_max, Nothing)

instance (Fractional f, Ord f) => BoundedHitable f (BoundingBox f) where
    boundingBox (BoundingBox l h _) = (l,h)

data SplitDirection = X | Y | Z

initializeBVH :: (Fractional f, Ord f) => V.Vector (BoundedHitableItem f) -> BoundingBox f
initializeBVH = go X
  where
    go direction v
      | V.null v = BoundingBox 0 0 V.empty
      | V.length v <= 5 =
          let (l,h) =
                  V.foldl1'
                      (\(P l1, P h1) (P l2, P h2) ->
                           (P (mzipWith min l1 l2), P (mzipWith max h1 h2)))
                      (V.map boundingBox v)
          in BoundingBox l h v
      | otherwise =
          let v1_count = V.length v `div` 2
              splitted = runST $ do
                  vm <- V.thaw v
                  VAI.selectBy (comparing (sortFun direction . centroid)) vm v1_count
                  V.unsafeFreeze vm
              (v1,v2) = V.splitAt v1_count splitted
              bb1@(BoundingBox (P l1) (P h1) _) = go (next direction) v1
              bb2@(BoundingBox (P l2) (P h2) _) = go (next direction) v2
              l = mzipWith min l1 l2
              h = mzipWith max h1 h2
          in BoundingBox (P l) (P h) (V.fromList $ map getBoundedHitableItem [bb1, bb2])
    sortFun :: SplitDirection -> Point V3 f -> f
    sortFun X = view _x
    sortFun Y = view _y
    sortFun Z = view _z
    next X = Y
    next Y = Z
    next Z = X