{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MagicHash #-}
#ifdef TRUSTWORTHY
{-# LANGUAGE Trustworthy #-}
#endif
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Lens.Internal
-- Copyright   :  (C) 2012 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  Rank2Types
--
-- These are some of the explicit Functor instances that leak into the
-- type signatures of Control.Lens. You shouldn't need to import this
-- module directly, unless you are coming up with a whole new kind of
-- \"Family\" and need to add instances.
--
----------------------------------------------------------------------------
module Control.Lens.Internal
  (
  -- * Internal Types
    May(..)
  , Folding(..)
  , Effect(..)
  , EffectRWS(..)
  , Accessor(..)
  , Err(..)
  , Traversed(..)
  , Sequenced(..)
  , Focusing(..)
  , FocusingWith(..)
  , FocusingPlus(..)
  , FocusingOn(..)
  , FocusingMay(..)
  , FocusingErr(..)
  , Mutator(..)
  , Bazaar(..), bazaar, duplicateBazaar, sell
  , BazaarT(..), bazaarT, duplicateBazaarT, sellT
  , Context(..)
  , Max(..), getMax
  , Min(..), getMin
  , Indexing(..)
  , Indexing64(..)
  -- * Overloadings
  , Prismoid(..)
  , Isoid(..)
  , Indexed(..)
  , CoA, CoB
  ) where

import Control.Applicative
import Control.Category
import Control.Comonad
import Control.Comonad.Store.Class
import Control.Lens.Classes
import Control.Monad
import Prelude hiding ((.),id)
import Data.Functor.Compose
import Data.Functor.Identity
import Data.Int
import Data.Monoid
#ifndef SAFE
import Unsafe.Coerce
#endif

#ifndef SAFE
#define UNSAFELY(x) unsafeCoerce
#else
#define UNSAFELY(f) (\g -> g `seq` \x -> (f) (g x))
#endif

-----------------------------------------------------------------------------
-- Functors
-----------------------------------------------------------------------------

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.State.StateT'
newtype Focusing m s a = Focusing { unfocusing :: m (s, a) }

instance Monad m => Functor (Focusing m s) where
  fmap f (Focusing m) = Focusing $ do
     (s, a) <- m
     return (s, f a)

instance (Monad m, Monoid s) => Applicative (Focusing m s) where
  pure a = Focusing (return (mempty, a))
  Focusing mf <*> Focusing ma = Focusing $ do
    (s, f) <- mf
    (s', a) <- ma
    return (mappend s s', f a)

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.RWS.RWST'
newtype FocusingWith w m s a = FocusingWith { unfocusingWith :: m (s, a, w) }

instance Monad m => Functor (FocusingWith w m s) where
  fmap f (FocusingWith m) = FocusingWith $ do
     (s, a, w) <- m
     return (s, f a, w)

instance (Monad m, Monoid s, Monoid w) => Applicative (FocusingWith w m s) where
  pure a = FocusingWith (return (mempty, a, mempty))
  FocusingWith mf <*> FocusingWith ma = FocusingWith $ do
    (s, f, w) <- mf
    (s', a, w') <- ma
    return (mappend s s', f a, mappend w w')

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.Writer.WriterT'.
newtype FocusingPlus w k s a = FocusingPlus { unfocusingPlus :: k (s, w) a }

instance Functor (k (s, w)) => Functor (FocusingPlus w k s) where
  fmap f (FocusingPlus as) = FocusingPlus (fmap f as)

instance (Monoid w, Applicative (k (s, w))) => Applicative (FocusingPlus w k s) where
  pure = FocusingPlus . pure
  FocusingPlus kf <*> FocusingPlus ka = FocusingPlus (kf <*> ka)

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.Trans.Maybe.MaybeT' or 'Control.Monad.Trans.List.ListT'
newtype FocusingOn f k s a = FocusingOn { unfocusingOn :: k (f s) a }

instance Functor (k (f s)) => Functor (FocusingOn f k s) where
  fmap f (FocusingOn as) = FocusingOn (fmap f as)

instance Applicative (k (f s)) => Applicative (FocusingOn f k s) where
  pure = FocusingOn . pure
  FocusingOn kf <*> FocusingOn ka = FocusingOn (kf <*> ka)

-- | Make a monoid out of 'Maybe' for error handling
newtype May a = May { getMay :: Maybe a }

instance Monoid a => Monoid (May a) where
  mempty = May (Just mempty)
  May Nothing `mappend` _ = May Nothing
  _ `mappend` May Nothing = May Nothing
  May (Just a) `mappend` May (Just b) = May (Just (mappend a b))

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.Error.ErrorT'
newtype FocusingMay k s a = FocusingMay { unfocusingMay :: k (May s) a }

instance Functor (k (May s)) => Functor (FocusingMay k s) where
  fmap f (FocusingMay as) = FocusingMay (fmap f as)

instance Applicative (k (May s)) => Applicative (FocusingMay k s) where
  pure = FocusingMay . pure
  FocusingMay kf <*> FocusingMay ka = FocusingMay (kf <*> ka)

-- | Make a monoid out of 'Either' for error handling
newtype Err e a = Err { getErr :: Either e a }

instance Monoid a => Monoid (Err e a) where
  mempty = Err (Right mempty)
  Err (Left e) `mappend` _ = Err (Left e)
  _ `mappend` Err (Left e) = Err (Left e)
  Err (Right a) `mappend` Err (Right b) = Err (Right (mappend a b))

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.Error.ErrorT'
newtype FocusingErr e k s a = FocusingErr { unfocusingErr :: k (Err e s) a }

instance Functor (k (Err e s)) => Functor (FocusingErr e k s) where
  fmap f (FocusingErr as) = FocusingErr (fmap f as)

instance Applicative (k (Err e s)) => Applicative (FocusingErr e k s) where
  pure = FocusingErr . pure
  FocusingErr kf <*> FocusingErr ka = FocusingErr (kf <*> ka)

-- | Applicative composition of @'Control.Monad.Trans.State.Lazy.State' 'Int'@ with a 'Functor', used
-- by 'Control.Lens.Indexed.indexed'
newtype Indexing f a = Indexing { runIndexing :: Int -> (f a, Int) }

instance Functor f => Functor (Indexing f) where
  fmap f (Indexing m) = Indexing $ \i -> case m i of
    (x, j) -> (fmap f x, j)

instance Applicative f => Applicative (Indexing f) where
  pure x = Indexing (\i -> (pure x, i))
  Indexing mf <*> Indexing ma = Indexing $ \i -> case mf i of
    (ff, j) -> case ma j of
       ~(fa, k) -> (ff <*> fa, k)

instance Gettable f => Gettable (Indexing f) where
  coerce (Indexing m) = Indexing $ \i -> case m i of
    (ff, j) -> (coerce ff, j)

-- | Applicative composition of @'Control.Monad.Trans.State.Lazy.State' 'Int'@ with a 'Functor', used
-- by 'Control.Lens.Indexed.indexed'
newtype Indexing64 f a = Indexing64 { runIndexing64 :: Int64 -> (f a, Int64) }

instance Functor f => Functor (Indexing64 f) where
  fmap f (Indexing64 m) = Indexing64 $ \i -> case m i of
    (x, j) -> (fmap f x, j)

instance Applicative f => Applicative (Indexing64 f) where
  pure x = Indexing64 (\i -> (pure x, i))
  Indexing64 mf <*> Indexing64 ma = Indexing64 $ \i -> case mf i of
    (ff, j) -> case ma j of
       ~(fa, k) -> (ff <*> fa, k)

instance Gettable f => Gettable (Indexing64 f) where
  coerce (Indexing64 m) = Indexing64 $ \i -> case m i of
    (ff, j) -> (coerce ff, j)

-- | Used internally by 'Control.Lens.Traversal.traverseOf_' and the like.
newtype Traversed f = Traversed { getTraversed :: f () }

instance Applicative f => Monoid (Traversed f) where
  mempty = Traversed (pure ())
  Traversed ma `mappend` Traversed mb = Traversed (ma *> mb)

-- | Used internally by 'Control.Lens.Traversal.mapM_' and the like.
newtype Sequenced m = Sequenced { getSequenced :: m () }

instance Monad m => Monoid (Sequenced m) where
  mempty = Sequenced (return ())
  Sequenced ma `mappend` Sequenced mb = Sequenced (ma >> mb)

-- | Used for 'Control.Lens.Fold.minimumOf'
data Min a = NoMin | Min a

instance Ord a => Monoid (Min a) where
  mempty = NoMin
  mappend NoMin m = m
  mappend m NoMin = m
  mappend (Min a) (Min b) = Min (min a b)

-- | Obtain the minimum.
getMin :: Min a -> Maybe a
getMin NoMin   = Nothing
getMin (Min a) = Just a

-- | Used for 'Control.Lens.Fold.maximumOf'
data Max a = NoMax | Max a

instance Ord a => Monoid (Max a) where
  mempty = NoMax
  mappend NoMax m = m
  mappend m NoMax = m
  mappend (Max a) (Max b) = Max (max a b)

-- | Obtain the maximum
getMax :: Max a -> Maybe a
getMax NoMax   = Nothing
getMax (Max a) = Just a

-- | The indexed store can be used to characterize a 'Control.Lens.Type.Lens'
-- and is used by 'Control.Lens.Type.clone'
--
-- @'Context' a b t@ is isomorphic to
-- @newtype Context a b t = Context { runContext :: forall f. Functor f => (a -> f b) -> f t }@,
-- and to @exists s. (s, 'Control.Lens.Type.Lens' s t a b)@.
--
-- A 'Context' is like a 'Control.Lens.Type.Lens' that has already been applied to a some structure.
data Context a b t = Context (b -> t) a

instance Functor (Context a b) where
  fmap f (Context g t) = Context (f . g) t

instance (a ~ b) => Comonad (Context a b) where
  extract   (Context f a) = f a
  duplicate (Context f a) = Context (Context f) a
  extend g  (Context f a) = Context (g . Context f) a

instance (a ~ b) => ComonadStore a (Context a b) where
  pos (Context _ a) = a
  peek b (Context g _) = g b
  peeks f (Context g a) = g (f a)
  seek a (Context g _) = Context g a
  seeks f (Context g a) = Context g (f a)
  experiment f (Context g a) = g <$> f a

-- | This is used to characterize a 'Control.Lens.Traversal.Traversal'.
--
-- a.k.a. indexed Cartesian store comonad, indexed Kleene store comonad, or an indexed 'FunList'.
--
-- <http://twanvl.nl/blog/haskell/non-regular1>
--
-- @'Bazaar' a b t@ is isomorphic to @data Bazaar a b t = Buy t | Trade (Bazaar a b (b -> t)) a@,
-- and to @exists s. (s, 'Control.Lens.Traversal.Traversal' s t a b)@.
--
-- A 'Bazaar' is like a 'Control.Lens.Traversal.Traversal' that has already been applied to some structure.
--
-- Where a @'Context' a b t@ holds an @a@ and a function from @b@ to
-- @t@, a @'Bazaar' a b t@ holds N @a@s and a function from N
-- @b@s to @t@.
--
-- Mnemonically, a 'Bazaar' holds many stores and you can easily add more.
--
-- This is a final encoding of 'Bazaar'.
newtype Bazaar a b t = Bazaar { runBazaar :: forall f. Applicative f => (a -> f b) -> f t }

instance Functor (Bazaar a b) where
  fmap f (Bazaar k) = Bazaar (fmap f . k)

instance Applicative (Bazaar a b) where
  pure a = Bazaar (\_ -> pure a)
  {-# INLINE pure #-}
  Bazaar mf <*> Bazaar ma = Bazaar (\k -> mf k <*> ma k)
  {-# INLINE (<*>) #-}

instance (a ~ b) => Comonad (Bazaar a b) where
  extract (Bazaar m) = runIdentity (m Identity)
  {-# INLINE extract #-}
  duplicate = duplicateBazaar
  {-# INLINE duplicate #-}

-- | Given an action to run for each matched pair, traverse a bazaar.
--
-- @'bazaar' :: 'Control.Lens.Traversal.Traversal' ('Bazaar' a b t) t a b@
bazaar :: Applicative f => (a -> f b) -> Bazaar a b t -> f t
bazaar afb (Bazaar m) = m afb
{-# INLINE bazaar #-}

-- | 'Bazaar' is an indexed 'Comonad'.
duplicateBazaar :: Bazaar a c t -> Bazaar a b (Bazaar b c t)
duplicateBazaar (Bazaar m) = getCompose (m (Compose . fmap sell . sell))
{-# INLINE duplicateBazaar #-}

-- | A trivial 'Bazaar'.
sell :: a -> Bazaar a b b
sell i = Bazaar (\k -> k i)
{-# INLINE sell #-}

instance (a ~ b) => ComonadApply (Bazaar a b) where
  (<@>) = (<*>)

-- | Wrap a monadic effect with a phantom type argument.
newtype Effect m r a = Effect { getEffect :: m r }

instance Functor (Effect m r) where
  fmap _ (Effect m) = Effect m

instance (Monad m, Monoid r) => Monoid (Effect m r a) where
  mempty = Effect (return mempty)
  Effect ma `mappend` Effect mb = Effect (liftM2 mappend ma mb)

instance (Monad m, Monoid r) => Applicative (Effect m r) where
  pure _ = Effect (return mempty)
  Effect ma <*> Effect mb = Effect (liftM2 mappend ma mb)

instance Gettable (Effect m r) where
  coerce (Effect m) = Effect m

instance Monad m => Effective m r (Effect m r) where
  effective = Effect
  {-# INLINE effective #-}
  ineffective = getEffect
  {-# INLINE ineffective #-}

-- | Wrap a monadic effect with a phantom type argument. Used when magnifying RWST.
newtype EffectRWS w st m s a = EffectRWS { getEffectRWS :: st -> m (s,st,w) }

instance Functor (EffectRWS w st m s) where
  fmap _ (EffectRWS m) = EffectRWS m

instance Gettable (EffectRWS w st m s) where
  coerce (EffectRWS m) = EffectRWS m

-- Effective EffectRWS

instance (Monoid s, Monoid w, Monad m) => Applicative (EffectRWS w st m s) where
  pure _ = EffectRWS $ \st -> return (mempty, st, mempty)
  EffectRWS m <*> EffectRWS n = EffectRWS $ \st -> m st >>= \ (s,t,w) -> n t >>= \ (s',u,w') -> return (mappend s s', u, mappend w w')

{-
-- | Wrap a monadic effect with a phantom type argument. Used when magnifying StateT.
newtype EffectS st k s a = EffectS { runEffect :: st -> k (s, st) a }

instance Functor (k (s, st)) => Functor (EffectS st m s) where
  fmap f (EffectS m) = EffectS (fmap f . m)

instance (Monoid s, Monad m) => Applicative (EffectS st m s) where
  pure _ = EffectS $ \st -> return (mempty, st)
  EffectS m <*> EffectS n = EffectS $ \st -> m st >>= \ (s,t) -> n st >>= \ (s', u) -> return (mappend s s', u)
-}

-------------------------------------------------------------------------------
-- Accessors
-------------------------------------------------------------------------------

--instance Gettable (EffectS st m s) where
--  coerce (EffectS m) = EffectS m

-- | Used instead of 'Const' to report
--
-- @No instance of ('Control.Lens.Setter.Settable' 'Accessor')@
--
-- when the user attempts to misuse a 'Control.Lens.Setter.Setter' as a
-- 'Control.Lens.Getter.Getter', rather than a monolithic unification error.
newtype Accessor r a = Accessor { runAccessor :: r }

instance Functor (Accessor r) where
  fmap _ (Accessor m) = Accessor m

instance Monoid r => Applicative (Accessor r) where
  pure _ = Accessor mempty
  Accessor a <*> Accessor b = Accessor (mappend a b)

instance Gettable (Accessor r) where
  coerce (Accessor m) = Accessor m

instance Effective Identity r (Accessor r) where
  effective = Accessor . runIdentity
  {-# INLINE effective #-}
  ineffective = Identity . runAccessor
  {-# INLINE ineffective #-}

-- | A 'Monoid' for a 'Gettable' 'Applicative'.
newtype Folding f a = Folding { getFolding :: f a }

instance (Gettable f, Applicative f) => Monoid (Folding f a) where
  mempty = Folding noEffect
  {-# INLINE mempty #-}
  Folding fr `mappend` Folding fs = Folding (fr *> fs)
  {-# INLINE mappend #-}

-----------------------------------------------------------------------------
-- Mutators
-----------------------------------------------------------------------------

-- | 'Mutator' is just a renamed 'Identity' functor to give better error
-- messages when someone attempts to use a getter as a setter.
--
-- Most user code will never need to see this type.
newtype Mutator a = Mutator { runMutator :: a }

instance Functor Mutator where
  fmap f (Mutator a) = Mutator (f a)
  {-# INLINE fmap #-}

instance Applicative Mutator where
  pure = Mutator
  {-# INLINE pure #-}
  Mutator f <*> Mutator a = Mutator (f a)
  {-# INLINE (<*>) #-}

instance Settable Mutator where
  untainted = runMutator
  untainted# = UNSAFELY(runMutator)
  {-# INLINE untainted #-}
  tainted# = UNSAFELY(Mutator)
  {-# INLINE tainted# #-}

-- | 'BazaarT' is like 'Bazaar', except that it provides a questionable 'Gettable' instance
-- To protect this instance it relies on the soundness of another 'Gettable' type, and usage conventions.
--
-- For example. This lets us write a suitably polymorphic and lazy 'Control.Lens.Traversal.taking', but there
-- must be a better way!
--
newtype BazaarT a b (g :: * -> *) t = BazaarT { runBazaarT :: forall f. Applicative f => (a -> f b) -> f t }

instance Functor (BazaarT a b g) where
  fmap f (BazaarT k) = BazaarT (fmap f . k)
  {-# INLINE fmap #-}

instance Applicative (BazaarT a b g) where
  pure a = BazaarT (\_ -> pure a)
  {-# INLINE pure #-}
  BazaarT mf <*> BazaarT ma = BazaarT (\k -> mf k <*> ma k)
  {-# INLINE (<*>) #-}

instance (a ~ b) => Comonad (BazaarT a b g) where
  extract (BazaarT m) = runIdentity (m Identity)
  {-# INLINE extract #-}
  duplicate = duplicateBazaarT
  {-# INLINE duplicate #-}

instance Gettable g => Gettable (BazaarT a b g) where
  coerce = (<$) (error "coerced BazaarT")
  {-# INLINE coerce #-}

-- | Extract from a 'BazaarT'.
--
-- @'bazaarT' = 'flip' 'runBazaarT'@
bazaarT :: Applicative f => (a -> f b) -> BazaarT a b g t -> f t
bazaarT afb (BazaarT m) = m afb
{-# INLINE bazaarT #-}

-- | 'BazaarT' is an indexed 'Comonad'.
duplicateBazaarT :: BazaarT a c f t -> BazaarT a b f (BazaarT b c f t)
duplicateBazaarT (BazaarT m) = getCompose (m (Compose . fmap sellT . sellT))
{-# INLINE duplicateBazaarT #-}

-- | A trivial 'BazaarT'.
sellT :: a -> BazaarT a b f b
sellT i = BazaarT (\k -> k i)
{-# INLINE sellT #-}

------------------------------------------------------------------------------
-- Prism Internals
------------------------------------------------------------------------------

type family ArgOf (f_b :: *) :: *
type instance ArgOf (f b) = b

-- | Extract @a@ from the type @a -> f b@
type family CoA x :: *

-- | Extract @b@ from the type @a -> f b@
type family CoB x :: *
type instance CoA (a -> f_b) = a
type instance CoB (a -> f_b) = ArgOf f_b

-- | This data type is used to capture all of the information provided by the
-- 'Prismatic' class, so you can turn a 'Prism' around into a 'Getter' or
-- otherwise muck around with its internals.
--
-- If you see a function that expects a 'Prismoid' or 'APrism', it is probably
-- just expecting a 'Prism'.
data Prismoid ab st where
  Prismoid :: Prismoid x x
  Prism :: (CoB x -> CoB y) -> (CoA y -> Either (CoB y) (CoA x)) -> Prismoid x y

instance Category Prismoid where
  id = Prismoid
  x . Prismoid = x
  Prismoid . x = x
  Prism ty xeys . Prism bt seta = Prism (ty.bt) $ \x ->
    case xeys x of
      Left y  -> Left y
      Right s -> case seta s of
        Left t  -> Left (ty t)
        Right a -> Right a

instance Isomorphic Prismoid where
  iso sa bt = Prism bt (Right . sa)
  {-# INLINE iso #-}

instance Prismatic Prismoid where
  prism    = Prism
  {-# INLINE prism #-}

------------------------------------------------------------------------------
-- Isomorphism Internals
------------------------------------------------------------------------------

-- | Reify all of the information given to you by being 'Isomorphic'.
data Isoid ab st where
  Isoid :: Isoid ab ab
  Iso   :: (CoA y -> CoA x) -> (CoB x -> CoB y) -> Isoid x y

instance Category Isoid where
  id = Isoid
  Isoid . x = x
  x . Isoid = x
  Iso xs ty . Iso sa bt = Iso (sa.xs) (ty.bt)

instance Isomorphic Isoid where
  iso   = Iso
  {-# INLINE iso #-}

------------------------------------------------------------------------------
-- Indexed Internals
------------------------------------------------------------------------------

-- | A function with access to a index. This constructor may be useful when you need to store
-- a 'Indexable' in a container to avoid @ImpredicativeTypes@.
--
-- @'withIndex' '.' 'indexed' ≡ 'id'@
newtype Indexed i a b = Indexed { withIndex :: (i -> a) -> b }

-- | Using an equality witness to avoid potential overlapping instances
-- and aid dispatch.
instance i ~ j => Indexable i (Indexed j) where
  indexed = Indexed
  {-# INLINE indexed #-}
